import AppKit

/// `MenuStats --benchmark`: average cost of each reader and of rendering the menu bar, to find what to optimize.
enum Benchmark {
    static func run() {
        func time(_ name: String, runs: Int = 20, _ body: () -> Void) {
            body() // warm up (first samples set baselines)
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<runs { body() }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(runs)
            print(String(format: "%-28@ %7.2f ms", name as NSString, ms))
        }
        let cpu = CPUReader(), memory = MemoryReader(), network = NetworkReader(), disk = DiskReader()
        let battery = BatteryReader(), sensors = SensorsReader(), smc = SMCReader(), processes = ProcessReader()
        time("CPU") { _ = cpu.sample() }
        time("Memoria") { _ = memory.sample() }
        time("Rete") { _ = network.sample() }
        time("Disco") { _ = disk.sample() }
        time("Batteria") { _ = battery.sample() }
        time("Sensori (HID)") { _ = sensors.sample() }
        time("SMC (ventole, potenza)") { _ = smc.sample() }
        time("Processi") { _ = processes.sample() }
        time("Volumi") { _ = VolumeReader.sample() }

        _ = NSApplication.shared
        let model = AppModel()
        model.tick(); model.tick()
        time("Tick completo (modello)") { model.tick() }
        let context = MenubarRenderer.Context(snapshot: model.snapshot, options: MenubarOptions(model.settings),
                                              recent: { model.recentValues($0, count: $1) })
        let modules = ModuleID.allCases
        time("Barra: composizione") { _ = MenubarRenderer.image(for: modules, context: context) }
        time("Barra: disegno 2x") {
            let image = MenubarRenderer.image(for: modules, context: context).image
            _ = MenubarRenderer.rasterize(image, dark: true)
        }
    }
}
