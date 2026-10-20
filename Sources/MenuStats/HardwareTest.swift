import AppKit
import CIOKitPrivate
import Foundation
import MenuStatsShared
import ServiceManagement

/// Command-line access to the helper, run from inside MenuStats.app:
/// `--install-helper`, `--uninstall-helper`, `--fan-test [fan] [rpm]` (fixes the speed for 8 s, back to automatic,
/// then fixes it again and exits without resetting, to check that the helper restores automatic mode by itself).
enum HardwareTest {
    static func install(_ enabled: Bool) {
        let service = SMAppService.daemon(plistName: HelperConstants.plistName(label: HardwareControl.helperLabel))
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
        print("Stato helper: \(describe(service.status))")
        if service.status == .requiresApproval {
            print("Consenti MenuStats in Impostazioni di Sistema ▸ Generali ▸ Elementi login.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func fanTest(fan: Int, rpm: Double) {
        let connection = NSXPCConnection(machServiceName: HardwareControl.helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MenuStatsHelperProtocol.self)
        connection.resume()
        let helper = connection.remoteObjectProxyWithErrorHandler { print("XPC: \($0.localizedDescription)") } as! MenuStatsHelperProtocol

        /// Waits at most 10 s for each reply, so a missing helper can't hang the test.
        func wait(_ label: String, _ body: (@escaping (String?) -> Void) -> Void) {
            let done = DispatchSemaphore(value: 0)
            body { error in print("\(label): \(error ?? "ok")"); done.signal() }
            if done.wait(timeout: .now() + 20) == .timedOut { print("\(label): nessuna risposta dall'helper"); exit(1) }
        }

        wait("Versione helper") { reply in helper.version { reply("\($0)") } }
        wait("Personalizzato \(Int(rpm)) giri/min") { helper.setFanSpeed(index: fan, rpm: rpm, reply: $0) }
        for _ in 0..<4 { Thread.sleep(forTimeInterval: 2); dump(fan) }
        wait("Automatico") { helper.setFanAutomatic(index: fan, reply: $0) }
        Thread.sleep(forTimeInterval: 2); dump(fan)
        wait("Sotto il minimo (1000), deve essere rifiutato") { helper.setFanSpeed(index: fan, rpm: 1000, reply: $0) }
        wait("Ventola inesistente, deve essere rifiutata") { helper.setFanSpeed(index: 9, rpm: rpm, reply: $0) }
        wait("Di nuovo personalizzato, poi uscita senza ripristino") { helper.setFanSpeed(index: fan, rpm: rpm, reply: $0) }
        Thread.sleep(forTimeInterval: 1); dump(fan)
    }

    /// `--lid-test`: the real lid-closed path through the installed helper, without closing the lid. Asks the helper to
    /// keep the Mac awake, checks macOS's own switch ("SleepDisabled", what `pmset -g` shows), renews the
    /// lease, releases it, and finally drops the connection while holding it, as a crash would, to check the helper
    /// gives sleep back by itself. Exit code 0 only if every check passes.
    static func lidTest() {
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            print(ok ? "  ✓ \(text)" : "  ✗ \(text)")
            if !ok { failures += 1 }
        }
        func sleepDisabled() -> Bool? {
            guard let settings = MSPMCopySystemPowerSettings() as? [String: Any] else { return nil }
            return (settings["SleepDisabled"] as? NSNumber)?.boolValue ?? false
        }
        func connect() -> (NSXPCConnection, MenuStatsHelperProtocol) {
            let connection = NSXPCConnection(machServiceName: HardwareControl.helperLabel, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MenuStatsHelperProtocol.self)
            connection.resume()
            let helper = connection.remoteObjectProxyWithErrorHandler { print("  XPC: \($0.localizedDescription)") } as! MenuStatsHelperProtocol
            return (connection, helper)
        }
        func wait<T>(_ body: (@escaping (T) -> Void) -> Void) -> T? {
            let done = DispatchSemaphore(value: 0)
            var result: T?
            body { result = $0; done.signal() }
            return done.wait(timeout: .now() + 20) == .timedOut ? nil : result
        }

        print("Coperchio chiuso, attraverso l'helper installato")
        let before = sleepDisabled()
        guard before == false else {
            print(before == nil ? "  ✗ impossibile leggere SleepDisabled" : "  · SleepDisabled è già attivo (pmset disablesleep 1?): prova saltata")
            exit(before == nil ? 1 : 0)
        }
        let (connection, helper) = connect()
        guard let version: Int = wait({ reply in helper.version { reply($0) } }) else { print("  ✗ l'helper non risponde"); exit(1) }
        print("  · helper versione \(version)")
        let acquired: String?? = wait { reply in helper.setLidAwake(true) { reply($0) } }
        check(acquired != nil && acquired! == nil, "l'helper accetta di tenere sveglio il Mac\((acquired ?? nil).map { ": \($0)" } ?? "")")
        check(sleepDisabled() == true, "macOS: stop disattivato (anche a coperchio chiuso)")
        let renewed: Bool? = wait { reply in helper.renewLidAwake { held, _ in reply(held) } }
        check(renewed == true, "rinnovo della concessione")
        _ = wait { (reply: @escaping (String?) -> Void) in helper.setLidAwake(false) { reply($0) } }
        Thread.sleep(forTimeInterval: 0.5)
        check(sleepDisabled() == false, "rilascio: lo stop torna normale")

        print("Uscita improvvisa dell'app mentre tiene sveglio il Mac")
        let again: String?? = wait { reply in helper.setLidAwake(true) { reply($0) } }
        check(again != nil && again! == nil && sleepDisabled() == true, "di nuovo sveglio")
        connection.invalidate()
        var restored = false
        for _ in 0..<20 where !restored {
            Thread.sleep(forTimeInterval: 0.25)
            restored = sleepDisabled() == false
        }
        check(restored, "l'helper ridà lo stop a macOS da solo quando l'app sparisce")
        print(failures == 0 ? "Coperchio: tutto corretto" : "Coperchio: \(failures) controlli falliti")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--lock-test`: locks the screen for real with the same call the proximity lock uses, checks that macOS reports
    /// it locked, then waits (up to 2 minutes) for the user to unlock.
    static func lockTest() {
        func locked() -> Bool {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
        print("Blocco schermo: lo schermo si blocca tra 3 secondi, poi sblocca come al solito.")
        guard SystemActions.screenIsUsable() else { print("  ✗ lo schermo risulta già bloccato o spento"); exit(1) }
        Thread.sleep(forTimeInterval: 3)
        SystemActions.lockScreen()
        var didLock = false
        for _ in 0..<40 where !didLock { Thread.sleep(forTimeInterval: 0.1); didLock = locked() }
        print(didLock ? "  ✓ macOS: schermo bloccato" : "  ✗ lo schermo non risulta bloccato")
        guard didLock else { exit(1) }
        var unlocked = false
        for _ in 0..<1200 where !unlocked { Thread.sleep(forTimeInterval: 0.1); unlocked = !locked() }
        print(unlocked ? "  ✓ sbloccato: il blocco automatico si riarma" : "  · ancora bloccato dopo 2 minuti")
        exit(didLock ? 0 : 1)
    }

    static func dump(_ fan: Int) {
        let smc = MSSMCOpen()
        defer { MSSMCClose(smc) }
        func read(_ key: String) -> String {
            var value = MSSMCValue()
            guard MSSMCRead(smc, key, &value) == 0 else { return "—" }
            let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(value.dataSize))) }
            if bytes.count == 4 { return String(format: "%.0f", bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) }
            return bytes.map { String($0) }.joined(separator: " ")
        }
        print("  Ftst=\(read("Ftst")) F\(fan)Md=\(read("F\(fan)Md")) F\(fan)Tg=\(read("F\(fan)Tg")) F\(fan)Ac=\(read("F\(fan)Ac"))")
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "non registrato"
        case .enabled: "attivo"
        case .requiresApproval: "da approvare"
        case .notFound: "plist non trovato nel bundle"
        @unknown default: "sconosciuto"
        }
    }
}
