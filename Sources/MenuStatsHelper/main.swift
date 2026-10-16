import CIOKitPrivate
import Foundation
import IOKit.pwr_mgt
import MenuStatsShared
import Darwin
import Security

// MenuStatsHelper: LaunchDaemon (root) that writes the fan keys of the SMC for MenuStats.
// Safety rules, all enforced here and not in the app:
// - only the exact MenuStats.app that contains this helper may connect (code-signing requirement on the connection);
// - speeds below the factory minimum or above the maximum are refused;
// - fans go back to automatic when the client disconnects (quit, crash), before sleep, on SIGTERM,
//   when macOS reports serious thermal pressure, and at helper start.

final class SMC {
    private let connection = MSSMCOpen()
    var isOpen: Bool { connection != 0 }

    func bytes(_ key: String) -> [UInt8]? {
        var value = MSSMCValue()
        guard MSSMCRead(connection, key, &value) == 0 else { return nil }
        return withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(value.dataSize))) }
    }

    func float(_ key: String) -> Double? {
        guard let bytes = bytes(key), bytes.count == 4 else { return nil }
        return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
    }

    func uint8(_ key: String) -> UInt8? { bytes(key)?.first }

    @discardableResult
    func write(_ key: String, _ bytes: [UInt8]) -> Int32 {
        Int32(MSSMCWrite(connection, key, bytes, UInt32(bytes.count)))
    }

    func write(_ key: String, float value: Double) -> Int32 {
        write(key, withUnsafeBytes(of: Float32(value)) { Array($0) })
    }
}

final class FanController {
    private let smc = SMC()
    private let queue = DispatchQueue(label: "local.menustats.helper.fans")
    /// Manual fan → the connection that set it; fans go back to automatic when that connection ends.
    private var manualFans: [Int: ObjectIdentifier] = [:]

    var fanCount: Int { min(Int(smc.uint8("FNum") ?? 0), 4) }

    /// Returns nil on success, otherwise an error message for the app.
    func setSpeed(index: Int, rpm: Double, owner: ObjectIdentifier) -> String? {
        queue.sync {
            guard smc.isOpen else { return "SMC non disponibile" }
            guard (0..<fanCount).contains(index) else { return "Ventola \(index) inesistente" }
            guard rpm.isFinite, let minimum = smc.float("F\(index)Mn"), let maximum = smc.float("F\(index)Mx"),
                  minimum > 0, maximum > minimum else { return "Limiti della ventola non leggibili" }
            guard rpm >= minimum.rounded(.down), rpm <= maximum.rounded(.up) else {
                return "Velocità fuori dai limiti di fabbrica (\(Int(minimum))–\(Int(maximum)) giri/min)"
            }
            guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else {
                return "Il Mac è sotto stress termico: le ventole restano in automatico"
            }
            // Apple Silicon: Ftst=1 unlocks manual mode; the firmware may take a moment before F{n}Md accepts writes.
            if smc.uint8("Ftst") != 1, smc.write("Ftst", [1]) != 0 { return "Scrittura di Ftst rifiutata" }
            // Right after Ftst returns to 0 the firmware needs several seconds before it accepts manual mode again.
            var modeResult: Int32 = -1
            for attempt in 1...150 {
                modeResult = smc.write("F\(index)Md", [1])
                if modeResult == 0, smc.uint8("F\(index)Md") == 1 { break }
                if attempt % 20 == 0 { smc.write("Ftst", [1]) }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard smc.uint8("F\(index)Md") == 1 else {
                restoreLocked()
                return "Modalità manuale rifiutata (F\(index)Md, codice \(modeResult))"
            }
            let target = min(max(rpm, minimum), maximum)
            guard smc.write("F\(index)Tg", float: target) == 0 else {
                restoreLocked()
                return "Velocità rifiutata (F\(index)Tg)"
            }
            manualFans[index] = owner
            NSLog("MenuStatsHelper: fan \(index) fixed at \(Int(target)) rpm")
            return nil
        }
    }

    func setAutomatic(index: Int) -> String? {
        queue.sync {
            guard (0..<fanCount).contains(index) else { return "Ventola \(index) inesistente" }
            smc.write("F\(index)Md", [0])
            manualFans[index] = nil
            if manualFans.isEmpty { smc.write("Ftst", [0]) }
            // The SMC applies the mode change asynchronously.
            for _ in 0..<30 where smc.uint8("F\(index)Md") == 1 { Thread.sleep(forTimeInterval: 0.1) }
            return smc.uint8("F\(index)Md") == 1 ? "La ventola non è tornata in automatico" : nil
        }
    }

    /// All fans back to automatic. Safe to call at any time, from any thread.
    func restore(reason: String) {
        queue.sync {
            guard isManual else { return }
            NSLog("MenuStatsHelper: fans back to automatic (\(reason))")
            restoreLocked()
        }
    }

    /// Fans set by `owner` back to automatic (its client quit or crashed).
    func restore(owner: ObjectIdentifier) {
        queue.sync {
            let owned = manualFans.filter { $0.value == owner }.map(\.key)
            guard !owned.isEmpty else { return }
            NSLog("MenuStatsHelper: client gone, fans \(owned) back to automatic")
            if owned.count == manualFans.count { restoreLocked(); return }
            for index in owned { smc.write("F\(index)Md", [0]); manualFans[index] = nil }
        }
    }

    var isManual: Bool { !manualFans.isEmpty || smc.uint8("Ftst") == 1 || (0..<fanCount).contains { smc.uint8("F\($0)Md") == 1 } }

    private func restoreLocked() {
        for index in 0..<fanCount { smc.write("F\(index)Md", [0]) }
        smc.write("Ftst", [0])
        manualFans.removeAll()
    }
}

final class HelperService: NSObject, MenuStatsHelperProtocol {
    let fans: FanController
    let owner: ObjectIdentifier
    init(fans: FanController, owner: ObjectIdentifier) { self.fans = fans; self.owner = owner }

    func version(reply: @escaping (Int) -> Void) { reply(HelperConstants.version) }
    func setFanSpeed(index: Int, rpm: Double, reply: @escaping (String?) -> Void) { reply(fans.setSpeed(index: index, rpm: rpm, owner: owner)) }
    func setFanAutomatic(index: Int, reply: @escaping (String?) -> Void) { reply(fans.setAutomatic(index: index)) }
    func resetFans(reply: @escaping (String?) -> Void) { fans.restore(reason: "richiesta dell'app"); reply(nil) }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let fans: FanController
    private var connections = 0
    private let lock = NSLock()

    init(fans: FanController) { self.fans = fans }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Read on every connection: reinstalling the app (new ad hoc cdhash) must not need a helper restart.
        guard let requirement = ListenerDelegate.clientRequirement() else {
            NSLog("MenuStatsHelper: cannot read the app's signature, refusing client")
            return false
        }
        // The kernel-verified identity of the peer must satisfy the requirement; checked on every message.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MenuStatsHelperProtocol.self)
        let owner = ObjectIdentifier(connection)
        connection.exportedObject = HelperService(fans: fans, owner: owner)
        connection.invalidationHandler = { [weak self] in self?.clientGone(owner) }
        lock.withLock { connections += 1 }
        connection.resume()
        return true
    }

    private func clientGone(_ owner: ObjectIdentifier) {
        fans.restore(owner: owner)
        let remaining = lock.withLock { connections -= 1; return connections }
        guard remaining <= 0 else { return }
        fans.restore(reason: "nessuna app collegata")
        // Nothing left to do: exit, so launchd starts the current binary on the next connection (after a reinstall).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.lock.withLock({ self?.connections ?? 0 }) == 0 { exit(0) }
        }
    }

    /// Requirement matching the MenuStats.app this helper ships in: by Team ID when Developer ID signed,
    /// otherwise by the exact code hash of the app (ad hoc signatures have no certificate to pin).
    static func clientRequirement() -> String? {
        // launchd starts BundleProgram with a relative argv[0], so ask the kernel for the absolute path.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { return nil }
        let helper = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: SecStaticCode?
        guard app.pathExtension == "app", SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == HelperConstants.appIdentifier else { return nil }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String {
            return "identifier \"\(HelperConstants.appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let hash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "identifier \"\(HelperConstants.appIdentifier)\" and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    }
}

// MARK: - Sleep and termination

let fans = FanController()
fans.restore(reason: "avvio dell'helper") // a previous helper may have died while fans were manual

// iokit_common_msg(0x280) and (0x270); the C macros don't import into Swift.
let messageSystemWillSleep: UInt32 = 0xE000_0280
let messageCanSystemSleep: UInt32 = 0xE000_0270
var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var powerPort: IONotificationPortRef?
rootPort = IORegisterForSystemPower(nil, &powerPort, { _, _, message, argument in
    switch message {
    case messageSystemWillSleep:
        fans.restore(reason: "stop")
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case messageCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    default:
        break
    }
}, &notifier)
if let powerPort { CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(powerPort).takeUnretainedValue(), .commonModes) }

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { fans.restore(reason: "helper terminato"); exit(0) }
    source.resume()
    signalSources.append(source)
}

// Thermal failsafe: a fixed speed can't ramp up under load, so serious thermal pressure hands control back to macOS.
let thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
    if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
        fans.restore(reason: "stress termico")
    }
}

let delegate = ListenerDelegate(fans: fans)
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
NSLog("MenuStatsHelper \(HelperConstants.version) ready")
RunLoop.main.run()
