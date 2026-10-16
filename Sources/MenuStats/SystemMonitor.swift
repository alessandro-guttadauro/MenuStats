import Foundation

/// Everything the UI needs for one refresh.
struct Snapshot {
    var date = Date()
    var cpu: CPUStats?
    var memory: MemoryStats?
    var network: NetworkStats?
    var disk: DiskStats?
    var volumes: [VolumeInfo] = []
    var battery: BatteryStats?
    var sensors = SensorStats(readings: [])
    var smc: SMCStats?
    var processes: [ProcessUsage] = []
    var thermalState: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false

    var ssdTemperature: Double? { sensors.readings.first { $0.name.contains("NAND") }?.celsius }
    /// CPU temperature as iStat Menus reports it (average of the SMC per-core sensors); HID die sensors as fallback.
    var cpuTemperature: Double? { smc?.cpuTemperature ?? sensors.cpuAverage }
    var cpuTemperatureMax: Double? { smc?.cpuTemperatureMax ?? sensors.cpuMax }
    var gpuTemperature: Double? { smc?.gpuTemperature }
    var maxFanRPM: Double? { smc?.fans.map(\.rpm).max() }
    var fansSpinning: Bool { (maxFanRPM ?? 0) > 0 }
}

/// Owns the readers and produces one Snapshot per refresh.
final class SystemMonitor {
    private let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let networkReader = NetworkReader()
    private let diskReader = DiskReader()
    private let batteryReader = BatteryReader()
    private let sensorsReader = SensorsReader()
    // Reading ~45 HID temperature services takes ~50 ms, so it runs on a background queue and is cached.
    private let sensorsQueue = DispatchQueue(label: "MenuStats.sensors", qos: .utility)
    private var sensors = SensorStats(readings: [])
    private var sensorsTime = -Double.infinity
    private var sensorsInFlight = false
    /// Seconds between temperature reads; the dashboard lowers it while the sensors tab is open.
    var sensorsInterval: Double = 5
    private let smcReader = SMCReader()
    private let processReader = ProcessReader()
    private var volumes: [VolumeInfo] = []
    private var volumesTime = 0.0

    func sample() -> Snapshot {
        // Volumes change rarely; refresh them every 10 seconds.
        let now = uptimeSeconds()
        if now - volumesTime > 10 {
            volumes = VolumeReader.sample()
            volumesTime = now
        }
        refreshSensorsIfNeeded(now: now)
        return Snapshot(
            cpu: cpuReader.sample(),
            memory: memoryReader.sample(),
            network: networkReader.sample(),
            disk: diskReader.sample(),
            volumes: volumes,
            battery: batteryReader.sample(),
            sensors: sensors,
            smc: smcReader.sample(),
            processes: processReader.sample(),
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Synchronous read, for one-shot tools (`--dump`, `--verify`).
    func sampleSensorsNow() {
        sensors = sensorsQueue.sync { sensorsReader.sample() }
        sensorsTime = uptimeSeconds()
    }

    private func refreshSensorsIfNeeded(now: Double) {
        guard !sensorsInFlight, now - sensorsTime >= sensorsInterval - 0.1 else { return }
        sensorsInFlight = true
        sensorsQueue.async { [self] in
            let readings = sensorsReader.sample()
            DispatchQueue.main.async { [self] in
                sensors = readings
                sensorsTime = uptimeSeconds()
                sensorsInFlight = false
            }
        }
    }
}
