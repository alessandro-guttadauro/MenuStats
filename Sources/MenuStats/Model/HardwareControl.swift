import AppKit
import CIOKitPrivate
import Combine
import MenuStatsShared
import ServiceManagement

/// Fan control and lid-closed awake (through the root helper) and the macOS charge limit (no root needed).
/// Custom fan speeds live only as long as the app: the helper puts fans back to automatic when MenuStats quits or
/// crashes and before sleep, so they are never saved.
final class HardwareControl: ObservableObject {
    enum HelperState: Equatable {
        case unavailable(String)   // not running from MenuStats.app
        case notInstalled
        case requiresApproval      // registered, waiting for System Settings ▸ General ▸ Login Items
        case installed
        case outdated

        var label: String {
            switch self {
            case .unavailable(let reason): reason
            case .notInstalled: "Non installato"
            case .requiresApproval: "Da approvare in Impostazioni di Sistema ▸ Generali ▸ Elementi login"
            case .installed: "Installato"
            case .outdated: "Versione vecchia: reinstalla"
            }
        }
    }

    @Published private(set) var helperState: HelperState = .notInstalled
    /// Fan index → fixed speed. Missing fans are automatic.
    @Published private(set) var fanTargets: [Int: Double] = [:]
    @Published private(set) var fanError: String?
    @Published private(set) var busy = false

    /// The helper keeps the Mac awake with the lid closed for this app.
    @Published private(set) var lidAwake = false
    /// Why the helper refused or dropped lid-closed awake; nil while it works or was never asked.
    @Published private(set) var lidError: String?
    /// Bumped on every lid request, so a late reply to an older one is ignored.
    private var lidRequest = 0

    @Published private(set) var chargeLimitSupported = false
    /// Current charge limit in percent, 100 when off; nil when unknown.
    @Published private(set) var chargeLimit: Int?
    @Published private(set) var chargeError: String?

    static let chargeLimits = [80, 90, 100]

    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshHelperState()
        refreshChargeLimit()
        // The helper hands fans back to macOS before sleep; mirror that here.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.fanTargets = [:] })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshChargeLimit() })
    }

    // MARK: Helper installation

    var canUseHelper: Bool { helperState == .installed }

    func refreshHelperState() {
        guard LoginItem.isAvailable else {
            helperState = .unavailable("Disponibile solo per l'app installata con scripts/install.sh")
            return
        }
        switch service.status {
        case .enabled:
            helperState = .installed
            checkVersion()
        case .requiresApproval: helperState = .requiresApproval
        default: helperState = .notInstalled
        }
    }

    func installHelper() {
        do {
            try service.register()
        } catch {
            fanError = "Installazione non riuscita: \(error.localizedDescription)"
        }
        refreshHelperState()
        if helperState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstallHelper() {
        let finish = { [weak self] in
            guard let self else { return }
            connection?.invalidate()
            connection = nil
            fanTargets = [:]
            lidAwake = false
            do { try service.unregister() } catch { fanError = "Rimozione non riuscita: \(error.localizedDescription)" }
            refreshHelperState()
        }
        guard canUseHelper else { finish(); return }
        call({ helper, done in helper.resetFans(reply: done) }) { _ in finish() }
    }

    private func checkVersion() {
        guard let helper = proxy({ _ in }) else { return }
        helper.version { [weak self] version in
            DispatchQueue.main.async {
                if version != HelperConstants.version { self?.helperState = .outdated }
            }
        }
    }

    // MARK: Lid closed

    /// Asks the helper to keep (or stop keeping) the Mac awake with the lid closed. Asking again renews the lease.
    func setLidAwake(_ on: Bool) {
        lidRequest += 1
        let request = lidRequest
        guard on else {
            guard lidAwake || connection != nil else { return }
            lidAwake = false
            call({ helper, done in helper.setLidAwake(false, reply: done) }) { _ in }
            return
        }
        guard canUseHelper else { lidAwake = false; lidError = "Installa l'helper per restare sveglio col coperchio chiuso"; return }
        call({ helper, done in helper.setLidAwake(true, reply: done) }) { [weak self] error in
            guard let self, request == lidRequest else { return }
            lidAwake = error == nil
            lidError = error
        }
    }

    /// Keeps the helper's lease alive; learns if a failsafe (heat, battery) gave sleep back to macOS.
    func renewLidAwake() {
        guard lidAwake, let helper = proxy({ _ in }) else { return }
        helper.renewLidAwake { [weak self] held, reason in
            DispatchQueue.main.async {
                guard let self, self.lidAwake, !held else { return }
                self.lidAwake = false
                self.lidError = reason.map { "Coperchio di nuovo attivo: \($0.lowercased())" } ?? "Coperchio di nuovo attivo"
            }
        }
    }

    // MARK: Fans

    /// `rpm == nil` → automatic.
    func setFan(_ index: Int, rpm: Double?) {
        guard canUseHelper else { fanError = "Installa prima l'helper"; return }
        busy = true
        call({ helper, done in
            if let rpm { helper.setFanSpeed(index: index, rpm: rpm.rounded(), reply: done) } else { helper.setFanAutomatic(index: index, reply: done) }
        }) { [weak self] error in
            guard let self else { return }
            busy = false
            fanError = error
            if error == nil { fanTargets[index] = rpm.map { $0.rounded() } } else if rpm != nil { fanTargets[index] = nil }
        }
    }

    func resetFans() {
        guard canUseHelper else { return }
        call({ helper, done in helper.resetFans(reply: done) }) { [weak self] error in
            self?.fanError = error
            if error == nil { self?.fanTargets = [:] }
        }
    }

    private func call(_ body: (MenuStatsHelperProtocol, @escaping (String?) -> Void) -> Void, completion: @escaping (String?) -> Void) {
        let done: (String?) -> Void = { error in DispatchQueue.main.async { completion(error) } }
        guard let helper = proxy({ error in done("Helper non raggiungibile: \(error.localizedDescription)") }) else {
            done("Helper non raggiungibile")
            return
        }
        body(helper, done)
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> MenuStatsHelperProtocol? {
        makeConnection().remoteObjectProxyWithErrorHandler(onError) as? MenuStatsHelperProtocol
    }

    /// One long-lived connection: the helper resets the fans when it goes away, i.e. when this process ends.
    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MenuStatsHelperProtocol.self)
        if let requirement = Self.helperRequirement() { connection.setCodeSigningRequirement(requirement) }
        let lost = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
                self?.fanTargets = [:] // the helper restored automatic mode
                if self?.lidAwake == true { // and let the Mac sleep with the lid closed again
                    self?.lidAwake = false
                    self?.lidError = "Helper riavviato: coperchio di nuovo attivo"
                }
            }
        }
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        connection.resume()
        self.connection = connection
        return connection
    }

    /// The helper must be the exact binary shipped inside this app bundle.
    private static func helperRequirement() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MenuStatsHelper")
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String else { return nil }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String {
            return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let hash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "identifier \"\(identifier)\" and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    }

    // MARK: Charge limit

    func refreshChargeLimit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let supported = MSChargeLimitSupported() == 1
            let limit = supported ? MSChargeLimitGet() : -1
            DispatchQueue.main.async {
                self?.chargeLimitSupported = supported
                self?.chargeLimit = limit >= 0 ? Int(limit) : nil
            }
        }
    }

    func setChargeLimit(_ percent: Int) {
        guard Self.chargeLimits.contains(percent) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MSChargeLimitSet(Int32(percent))
            let limit = MSChargeLimitGet()
            DispatchQueue.main.async {
                self?.chargeError = result == 0 && limit == percent ? nil : "macOS ha rifiutato il limite (codice \(result))"
                self?.chargeLimit = limit >= 0 ? Int(limit) : nil
            }
        }
    }
}
