import CIOKitPrivate
import Foundation

struct SensorReading {
    var name: String
    var celsius: Double
}

struct SensorStats {
    var readings: [SensorReading]

    /// CPU die sensors ("PMU tdie…") on Apple Silicon.
    var cpuSensors: [SensorReading] { readings.filter { $0.name.contains("tdie") } }
    var cpuAverage: Double? { Self.average(cpuSensors) }
    var cpuMax: Double? { cpuSensors.map(\.celsius).max() }
    var hottest: SensorReading? { readings.max { $0.celsius < $1.celsius } }
    var batteryTemperature: Double? { readings.first { $0.name.contains("battery") }?.celsius }

    private static func average(_ readings: [SensorReading]) -> Double? {
        readings.isEmpty ? nil : readings.map(\.celsius).reduce(0, +) / Double(readings.count)
    }
}

/// Temperature sensors exposed through the IOHID event system (Apple vendor usage page,
/// temperature usage). Works without root on Apple Silicon; Intel Macs expose these via the SMC instead.
final class SensorsReader {
    private let client: CFTypeRef?
    private var services: [CFTypeRef] = []
    private var names: [String] = []

    init() {
        client = MSHIDClientCreate(kCFAllocatorDefault)
        if let client {
            let matching: [String: Int] = [
                "PrimaryUsagePage": Int(MSHIDUsagePageAppleVendor),
                "PrimaryUsage": Int(MSHIDUsageTemperatureSensor),
            ]
            MSHIDClientSetMatching(client, matching as CFDictionary)
            refreshServices()
        }
    }

    func sample() -> SensorStats {
        if services.isEmpty { refreshServices() }

        // Several services share a name (one per PMU, several battery gauges): average them per name.
        var valuesByName: [String: [Double]] = [:]
        for (service, name) in zip(services, names) {
            guard let event = MSHIDServiceCopyEvent(service, Int64(MSHIDEventTypeTemperature), 0, 0) else { continue }
            let value = MSHIDEventGetFloatValue(event, Int32(MSHIDEventFieldTemperatureLevel))
            // Disconnected or idle sensors report 0 or nonsense values; "tcal" is a calibration constant, not a temperature.
            if value > 0, value < 150, !name.contains("tcal") {
                valuesByName[name, default: []].append(value)
            }
        }
        let readings = valuesByName
            .map { SensorReading(name: $0.key, celsius: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return SensorStats(readings: readings)
    }

    private func refreshServices() {
        guard let client, let list = MSHIDClientCopyServices(client) as? [CFTypeRef] else { return }
        services = list
        names = list.map { service in
            MSHIDServiceCopyProperty(service, "Product" as CFString) as? String ?? "Sensore"
        }
    }
}
