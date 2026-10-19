import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Reads memory, disk and battery from inside the (sandboxed) widget extension, so the widgets show current values
/// even while MenuStats is closed. All instant readings: no waiting, no special permissions.
enum LiveSampler {
    static func sample() -> WidgetData {
        WidgetData(updated: Date(), fahrenheit: false, chip: chip, memory: memory(), disk: disk(), battery: battery(), weather: nil)
    }

    /// "Apple M3 Pro".
    static let chip: String? = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()

    // MARK: Memory and disk

    private static func memory() -> WidgetData.Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let anonymous = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        let app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return WidgetData.Memory(used: app + wired + compressed, total: UInt64(sysctlInt("hw.memsize") ?? 0), app: app, wired: wired,
                                 compressed: compressed, pressure: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1, history: [])
    }

    private static func disk() -> WidgetData.Disk? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let block = UInt64(info.f_bsize)
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        return WidgetData.Disk(name: name, free: UInt64(info.f_bavail) * block, total: UInt64(info.f_blocks) * block)
    }

    // MARK: Battery

    private static func battery() -> WidgetData.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            var battery = WidgetData.Battery(percent: Double(current) / Double(maximum), charging: charging,
                                             pluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                             minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil, health: nil, cycles: nil, watts: nil)
            // Cycle count, health estimate and power from the battery's registry entry.
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func number(_ key: String) -> NSNumber? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                }
                battery.cycles = number("CycleCount")?.intValue
                if let nominal = number("NominalChargeCapacity")?.doubleValue, let design = number("DesignCapacity")?.doubleValue, design > 0 {
                    battery.health = min(nominal / design, 1)
                }
                if let millivolts = number("Voltage")?.doubleValue, let amperage = number("Amperage")?.intValue {
                    battery.watts = millivolts / 1000 * Double(Int16(truncatingIfNeeded: amperage)) / 1000
                }
            }
            return battery
        }
        return nil
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}
