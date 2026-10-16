import AppKit
import SwiftUI

let arguments = CommandLine.arguments

// `MenuStats --dump` prints one reading of everything to the terminal and exits.
if arguments.contains("--dump") {
    let monitor = SystemMonitor()
    _ = monitor.sample() // rates and CPU usage need two samples
    monitor.sampleSensorsNow()
    Thread.sleep(forTimeInterval: 1)
    let s = monitor.sample()
    if let cpu = s.cpu { print("CPU      \(Format.percent(cpu.total)) (utente \(Format.percent(cpu.user)), sistema \(Format.percent(cpu.system)))") }
    if let m = s.memory { print("Memoria  \(Format.percent(m.usedFraction)) · \(Format.bytes(m.used)) di \(Format.bytes(m.total)) · pressione \(m.pressureLevel)") }
    if let d = s.disk { print("Disco    R \(Format.rate(d.readRate)) · W \(Format.rate(d.writeRate))") }
    for v in s.volumes {
        print("Volume   \(v.name): usato \(Format.percent(v.usedFraction)) · liberi \(Format.storage(v.free)) · eliminabili \(Format.storage(v.purgeable)) · totale \(Format.storage(v.total))")
    }
    if let n = s.network { print("Rete     \(n.interface ?? "-") \(n.ipAddress ?? "") ↓ \(Format.rate(n.downloadRate)) ↑ \(Format.rate(n.uploadRate))") }
    print("Sensori  \(s.sensors.readings.count), CPU \(s.sensors.cpuAverage.map { Format.temperature($0) } ?? "-"), SSD \(s.ssdTemperature.map { Format.temperature($0) } ?? "-")")
    if let smc = s.smc {
        for fan in smc.fans { print("Ventola  \(fan.name): \(Format.rpm(fan.rpm)) (min \(Format.rpm(fan.minimum)), max \(Format.rpm(fan.maximum)))") }
        print("Potenza  sistema \(smc.systemPower.map(Format.watts) ?? "-"), alimentatore \(smc.adapterPower.map(Format.watts) ?? "-")")
    }
    if let b = s.battery {
        print("Batteria \(Format.percent(b.percent)) carica:\(b.isCharging) AC:\(b.onACPower) salute \(b.health.map(Format.percent) ?? "-") cicli \(b.cycleCount ?? 0) \(b.adapterWatts.map { "alimentatore \($0) W" } ?? "")")
    }
    print("Termica  \(s.thermalState.rawValue) · basso consumo \(s.lowPowerMode)")
    let groups = ProcessGrouping.groups(s.processes, byApp: true).sorted { $0.cpu > $1.cpu }.prefix(5)
    for g in groups { print("Processo \(g.name) ×\(g.count): \(Format.processCPU(g.cpu)) · \(Format.bytes(g.memory))") }
    exit(0)
}

if arguments.contains("--benchmark") {
    Benchmark.run()
    exit(0)
}

// Helper commands; run them from inside MenuStats.app (see HardwareTest).
if arguments.contains("--install-helper") { HardwareTest.install(true); exit(0) }
if arguments.contains("--uninstall-helper") { HardwareTest.install(false); exit(0) }
if let flag = arguments.firstIndex(of: "--fan-test") {
    let fan = arguments.count > flag + 1 ? Int(arguments[flag + 1]) ?? 0 : 0
    let rpm = arguments.count > flag + 2 ? Double(arguments[flag + 2]) ?? 3000 : 3000
    HardwareTest.fanTest(fan: fan, rpm: rpm)
    exit(0)
}

// `MenuStats --verify` compares every value with macOS's own tools.
if arguments.contains("--verify") {
    Verify.run()
    exit(0)
}

// `MenuStats --render-ui <dir>` renders the menu bar, every dashboard tab and the settings pages (light and dark) as PNG.
if let flag = arguments.firstIndex(of: "--render-ui"), flag + 1 < arguments.count {
    let directory = URL(fileURLWithPath: arguments[flag + 1])
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let model = AppModel()
    model.warmUpSensors()
    model.tick()
    Thread.sleep(forTimeInterval: 1)
    model.tick()
    Thread.sleep(forTimeInterval: 1)
    model.tick()
    UITestRenderer.renderAll(model: model, to: directory)
    print("Interfaccia salvata in \(directory.path)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
