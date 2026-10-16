import CIOKitPrivate
import Foundation
import MenuStatsShared
import ServiceManagement

/// Command-line access to the helper, run from inside MenuStats.app:
/// `--install-helper`, `--uninstall-helper`, `--fan-test [fan] [rpm]` (fixes the speed for 8 s, back to automatic,
/// then fixes it again and exits without resetting, to check that the helper restores automatic mode by itself).
enum HardwareTest {
    static func install(_ enabled: Bool) {
        let service = SMAppService.daemon(plistName: HelperConstants.plistName)
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
        let connection = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
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
