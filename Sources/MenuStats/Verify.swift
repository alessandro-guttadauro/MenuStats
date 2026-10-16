import Foundation

/// `MenuStats --verify`: compares every value MenuStats shows with macOS's own tools and prints ✓/✗.
enum Verify {
    private struct Check {
        var name: String
        var ours: String
        var reference: String
        var source: String
        var ok: Bool
    }

    static func run() {
        let monitor = SystemMonitor()
        OfficialBatteryInfo.shared.refreshIfNeeded()
        _ = monitor.sample()
        monitor.sampleSensorsNow()
        // Sample over the same 2 s window `top` uses below.
        let topOutput = AsyncShell("/usr/bin/top", ["-l", "2", "-s", "2", "-n", "0"])
        Thread.sleep(forTimeInterval: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let the System Information read land
        let s = monitor.sample()
        var checks: [Check] = []

        func add(_ name: String, _ ours: String, _ reference: String, _ source: String, _ ok: Bool) {
            checks.append(Check(name: name, ours: ours, reference: reference, source: source, ok: ok))
        }
        func number(_ text: String?) -> Double? {
            guard let text else { return nil }
            let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
            return Double(cleaned)
        }

        // CPU
        if let cpu = s.cpu, let line = topOutput.result().split(separator: "\n").last(where: { $0.hasPrefix("CPU usage") }) {
            let parts = line.split(separator: ",").map { number(String($0)) ?? 0 }
            let busy = (parts.count >= 2 ? parts[0] + parts[1] : 0) / 100
            add("CPU totale", Format.percent(cpu.total), Format.percent(busy), "top", abs(busy - cpu.total) < 0.12)
        }
        add("Core logici", "\(s.cpu?.perCore.count ?? 0)", shell("/usr/sbin/sysctl", ["-n", "hw.ncpu"]), "sysctl hw.ncpu",
            "\(s.cpu?.perCore.count ?? 0)" == shell("/usr/sbin/sysctl", ["-n", "hw.ncpu"]))
        if let cpu = s.cpu {
            let reference = shell("/usr/sbin/sysctl", ["-n", "vm.loadavg"]).split(separator: " ").compactMap { Double($0) }
            add("Carico 1 min", String(format: "%.2f", cpu.loadAverage[0]), reference.first.map { String(format: "%.2f", $0) } ?? "—",
                "sysctl vm.loadavg", abs((reference.first ?? -9) - cpu.loadAverage[0]) < 0.3)
        }

        // Memory
        if let memory = s.memory {
            let total = UInt64(shell("/usr/sbin/sysctl", ["-n", "hw.memsize"])) ?? 0
            add("RAM totale", Format.bytes(memory.total), Format.bytes(total), "sysctl hw.memsize", memory.total == total)
            let swap = shell("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
            let usedMB = swap.components(separatedBy: "used = ").dropFirst().first.flatMap { number(String($0.prefix(while: { $0 != "M" }))) } ?? -1
            add("Swap usato", Format.bytes(memory.swapUsed), String(format: "%.0f MB", usedMB), "sysctl vm.swapusage",
                abs(Double(memory.swapUsed) / 1_048_576 - usedMB) < 64)
            let level = shell("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
            add("Pressione memoria", "\(memory.pressureLevel)", level, "sysctl", "\(memory.pressureLevel)" == level)
        }

        // Disk (startup volume)
        if let disk = s.disk {
            let info = shell("/usr/sbin/diskutil", ["info", "/"])
            func bytes(_ key: String) -> UInt64? {
                info.split(separator: "\n").first { $0.contains(key) }
                    .flatMap { $0.components(separatedBy: "(").dropFirst().first }
                    .flatMap { UInt64($0.prefix(while: { $0.isNumber })) }
            }
            if let free = bytes("Container Free Space"), let total = bytes("Container Total Space") {
                add("Disco libero", Format.storage(disk.free), Format.storage(free), "diskutil",
                    abs(Double(disk.free) - Double(free)) < 2e8)
                add("Disco totale", Format.storage(disk.total), Format.storage(total), "diskutil", disk.total == total)
                let used = Double(total - free) / Double(total)
                add("Disco usato", Format.percent(disk.usedFraction), String(format: "%.1f%%", used * 100), "diskutil",
                    abs(used - disk.usedFraction) < 0.005)
            }
        }

        // Network
        if let network = s.network {
            let route = shell("/sbin/route", ["-n", "get", "default"]).split(separator: "\n")
                .first { $0.contains("interface:") }.map { String($0.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces) }
            add("Interfaccia", network.interface ?? "—", route ?? "—", "route get default", network.interface == route)
            if let interface = network.interface {
                let ip = shell("/usr/sbin/ipconfig", ["getifaddr", interface])
                add("Indirizzo IP", network.ipAddress ?? "—", ip, "ipconfig", network.ipAddress == ip)
            }
        }

        // Battery
        if let battery = s.battery {
            let pmset = shell("/usr/bin/pmset", ["-g", "batt"])
            let percent = pmset.range(of: #"\d+%"#, options: .regularExpression).map { String(pmset[$0]) } ?? "—"
            add("Carica batteria", Format.percent(battery.percent), percent, "pmset -g batt", Format.percent(battery.percent) == percent)
            // "finishing charge" is the last phase of charging (IOPowerSources still reports it as charging).
            let charging = pmset.contains("; charging;") || pmset.contains("finishing charge")
            add("In carica", battery.isCharging ? "sì" : "no", charging ? "sì" : "no", "pmset -g batt", battery.isCharging == charging)
            let ac = pmset.contains("AC Power")
            add("Alimentatore", battery.onACPower ? "sì" : "no", ac ? "sì" : "no", "pmset -g batt", battery.onACPower == ac)

            let profiler = shell("/usr/sbin/system_profiler", ["SPPowerDataType"])
            func field(_ key: String) -> String? {
                profiler.split(separator: "\n").first { $0.contains(key) }
                    .map { String($0.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces) }
            }
            if let maximum = field("Maximum Capacity") {
                add("Capacità massima", battery.health.map(Format.percent) ?? "—", maximum, "Informazioni di Sistema",
                    battery.health.map(Format.percent) == maximum)
            }
            if let cycles = field("Cycle Count") {
                add("Cicli", "\(battery.cycleCount ?? -1)", cycles, "Informazioni di Sistema", "\(battery.cycleCount ?? -1)" == cycles)
            }
        }

        // System state
        let bootSeconds = number(shell("/usr/sbin/sysctl", ["-n", "kern.boottime"]).components(separatedBy: "sec = ").dropFirst().first
            .map { String($0.prefix(while: { $0.isNumber })) }) ?? 0
        let uptime = Date().timeIntervalSince1970 - bootSeconds
        let days = Int(uptime) / 86_400, hours = Int(uptime) % 86_400 / 3600, minutes = Int(uptime) % 3600 / 60
        let reference = days > 0 ? "\(days) g \(hours) h \(minutes) min" : "\(hours) h \(minutes) min"
        add("Attivo da", Format.uptime(), reference, "sysctl kern.boottime", abs(uptime - Sysctl.secondsSinceBoot()) < 120)
        let lowPower = shell("/usr/bin/pmset", ["-g"]).split(separator: "\n").first { $0.contains("lowpowermode") }
            .map { $0.hasSuffix("1") } ?? false
        add("Basso consumo", s.lowPowerMode ? "sì" : "no", lowPower ? "sì" : "no", "pmset -g", s.lowPowerMode == lowPower)

        // Report
        let nameWidth = checks.map(\.name.count).max() ?? 10
        print("Verifica di attendibilità: MenuStats contro gli strumenti di macOS\n")
        for check in checks {
            print("\(check.ok ? "✓" : "✗") \(check.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  MenuStats \(check.ours.padding(toLength: 12, withPad: " ", startingAt: 0))  macOS \(check.reference.padding(toLength: 12, withPad: " ", startingAt: 0))  (\(check.source))")
        }
        let failures = checks.filter { !$0.ok }.count
        print("\n\(checks.count - failures)/\(checks.count) valori coincidono" + (failures > 0 ? ", \(failures) da controllare" : ""))
        print("Non verificabili senza root: temperature, ventole e potenza (powermetrics richiede l'amministratore).")
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Runs a command in the background while we sample, so both measure the same time window.
    private final class AsyncShell {
        private let task = Process()
        private let pipe = Pipe()

        init(_ path: String, _ arguments: [String]) {
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }

        func result() -> String {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
