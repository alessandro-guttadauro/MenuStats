import Foundation
import IOKit
import IOKit.ps

struct BatteryStats {
    var percent: Double
    var isCharging: Bool
    var onACPower: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is still estimating.
    var minutesRemaining: Int?
    var cycleCount: Int?
    /// Current full-charge capacity as a fraction of design capacity.
    var health: Double?
    var temperature: Double?
    /// Positive while charging, negative while discharging.
    var watts: Double?
    var isFullyCharged = false
    var designCapacity: Int?   // mAh
    var fullChargeCapacity: Int? // mAh
    var remainingCapacity: Int?  // mAh
    var voltage: Double?       // V
    var amperage: Double?      // A, signed
    var adapterWatts: Int?
    var adapterName: String?
    /// Apple's battery condition ("Normale", "Assistenza consigliata"), from System Information.
    var condition: String?
    /// True when `health` is Apple's own figure (System Information) rather than our estimate.
    var healthIsOfficial = false
}

/// Apple's own battery health (the "Maximum Capacity" shown in System Settings), read from
/// `system_profiler SPPowerDataType` in the background every 10 minutes: it changes slowly and our
/// nominal/design estimate can round differently from Apple's figure.
final class OfficialBatteryInfo {
    static let shared = OfficialBatteryInfo()
    private(set) var maximumCapacity: Double?
    private(set) var cycleCount: Int?
    private(set) var condition: String?
    private var lastRefresh: Date?
    private var refreshing = false

    func refreshIfNeeded() {
        guard !refreshing, lastRefresh.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["SPPowerDataType", "-json"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let entries = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["SPPowerDataType"] as? [[String: Any]] ?? []
            let health = entries.lazy.compactMap { $0["sppower_battery_health_info"] as? [String: Any] }.first
            DispatchQueue.main.async {
                if let health {
                    if let text = health["sppower_battery_health_maximum_capacity"] as? String,
                       let percent = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                        self.maximumCapacity = percent / 100
                    }
                    self.cycleCount = health["sppower_battery_cycle_count"] as? Int
                    self.condition = (health["sppower_battery_health"] as? String).map(Self.localizedCondition)
                }
                self.lastRefresh = Date()
                self.refreshing = false
            }
        }
    }

    private static func localizedCondition(_ value: String) -> String {
        switch value.lowercased() {
        case "good", "normal": "Normale"
        case "fair": "Discreta"
        case "poor", "check battery", "service recommended": "Assistenza consigliata"
        default: value
        }
    }
}

/// Battery state from IOPowerSources, plus health details from the AppleSmartBattery registry entry.
final class BatteryReader {
    func sample() -> BatteryStats? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = description[minutesKey] as? Int

            var stats = BatteryStats(
                percent: max > 0 ? Double(current) / Double(max) : 0,
                isCharging: charging,
                onACPower: onAC,
                minutesRemaining: (minutes ?? -1) >= 0 ? minutes : nil
            )
            stats.isFullyCharged = description[kIOPSIsChargedKey] as? Bool ?? false
            addSmartBatteryDetails(to: &stats)
            let official = OfficialBatteryInfo.shared
            official.refreshIfNeeded()
            if let maximum = official.maximumCapacity {
                stats.health = maximum
                stats.healthIsOfficial = true
            }
            stats.cycleCount = official.cycleCount ?? stats.cycleCount
            stats.condition = official.condition
            if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                stats.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
                stats.adapterName = adapter["Name"] as? String
            }
            return stats
        }
        return nil
    }

    private func addSmartBatteryDetails(to stats: inout BatteryStats) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return }

        // Recent macOS versions move capacity details into a nested "BatteryData" dictionary.
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> NSNumber? { (properties[key] ?? batteryData[key]) as? NSNumber }

        stats.cycleCount = number("CycleCount")?.intValue
        if let raw = number("Temperature")?.doubleValue, raw > 0 {
            stats.temperature = raw / 100 // centi-degrees Celsius
        }
        if let nominal = (number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"))?.doubleValue,
           let design = number("DesignCapacity")?.doubleValue, design > 0 {
            stats.health = nominal / design // estimate; replaced by Apple's figure when available
            stats.designCapacity = Int(design)
        }
        stats.fullChargeCapacity = (number("FullChargeCapacity") ?? number("NominalChargeCapacity"))?.intValue
        stats.remainingCapacity = (number("RemainingCapacity") ?? number("AppleRawCurrentCapacity"))?.intValue
        if let millivolts = number("Voltage")?.doubleValue, let amperage = number("Amperage") {
            // Amperage is a signed mA value that IOKit sometimes reports as an unsigned 64-bit integer.
            let milliamps = Double(Int64(bitPattern: amperage.uint64Value))
            stats.watts = millivolts * milliamps / 1_000_000
            stats.voltage = millivolts / 1000
            stats.amperage = milliamps / 1000
        }
    }
}
