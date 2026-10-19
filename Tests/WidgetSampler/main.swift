import Foundation

// Checks the widget extension's own system readings (LiveSampler) against independent sources.
// Built by scripts/test.sh together with the extension's sources, exactly as build-app.sh compiles them.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
    if !condition { failures += 1 }
}
func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

let data = LiveSampler.sample()
print("Campionatore dei widget")

if let memory = data.memory {
    let physical = UInt64(shell("sysctl -n hw.memsize")) ?? 0
    check(memory.total == physical, "memoria totale \(WidgetFormat.bytes(memory.total)) = sysctl hw.memsize")
    check(memory.used > 0 && memory.used < memory.total, "memoria usata \(WidgetFormat.bytes(memory.used))")
    check([1, 2, 4].contains(memory.pressure), "pressione memoria \(memory.pressure)")
} else { check(false, "memoria letta") }

if let disk = data.disk {
    // df -k: 1024-byte blocks, total and available on /.
    let fields = shell("df -k / | tail -1").split(separator: " ")
    let total = (UInt64(fields[1]) ?? 0) * 1024, available = (UInt64(fields[3]) ?? 0) * 1024
    check(abs(Double(disk.total) - Double(total)) / Double(total) < 0.01, "disco totale \(WidgetFormat.storage(disk.total)) ≈ df")
    check(abs(Double(disk.free) - Double(available)) < 2e9, "disco libero \(WidgetFormat.storage(disk.free)) ≈ df (±2 GB)")
} else { check(false, "disco letto") }

let pmset = shell("pmset -g batt")
if let battery = data.battery {
    let percent = pmset.range(of: #"(\d+)%"#, options: .regularExpression).map { Int(pmset[$0].dropLast()) ?? -1 } ?? -1
    check(abs(Int((battery.percent * 100).rounded()) - percent) <= 1, "batteria \(WidgetFormat.percent(battery.percent)) = pmset (\(percent)%)")
    check(battery.cycles.map { $0 > 0 } ?? false, "cicli batteria \(battery.cycles ?? 0)")
} else {
    check(!pmset.contains("InternalBattery"), "nessuna batteria (Mac senza batteria)")
}

check(data.chip?.hasPrefix("Apple") ?? false, "chip \(data.chip ?? "-")")

let started = Date()
_ = LiveSampler.sample()
check(Date().timeIntervalSince(started) < 0.5, "lettura istantanea (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")

print(failures == 0 ? "Campionatore: tutto corretto" : "Campionatore: \(failures) controlli falliti")
exit(failures == 0 ? 0 : 1)
