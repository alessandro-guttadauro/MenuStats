import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Reads the system from inside the (sandboxed) widget extension, so the widgets show current values even while
/// MenuStats is closed. Rates (CPU, network, disk) come from two readings one second apart.
enum LiveSampler {
    static func sample() -> WidgetData {
        let cpuStart = cpuTicks(), networkStart = networkCounters(), diskStart = diskCounters()
        let start = Date()
        Thread.sleep(forTimeInterval: 1)
        let elapsed = max(Date().timeIntervalSince(start), 0.1)
        let cpuEnd = cpuTicks(), networkEnd = networkCounters(), diskEnd = diskCounters()

        let smc = SMCSample.read()
        return WidgetData(
            updated: Date(), fahrenheit: false, chip: SMCSensorMap.chip,
            cpu: cpu(cpuStart, cpuEnd),
            memory: memory(),
            disk: disk(read: Double(diskEnd.read &- diskStart.read) / elapsed, write: Double(diskEnd.write &- diskStart.write) / elapsed),
            network: WidgetData.Network(download: Double(networkEnd.received &- networkStart.received) / elapsed,
                                        upload: Double(networkEnd.sent &- networkStart.sent) / elapsed,
                                        interface: networkEnd.interface, address: networkEnd.address,
                                        downloadHistory: [], uploadHistory: []),
            temperature: smc.cpu.map {
                WidgetData.Temperature(cpu: $0, cpuMax: smc.cpuMax, gpu: smc.gpu, ssd: nil,
                                       thermalState: ProcessInfo.processInfo.thermalState.rawValue, history: [])
            },
            fans: smc.fans,
            battery: battery(),
            weather: nil
        )
    }

    // MARK: CPU

    private struct Ticks { var user, system, idle, nice: UInt32 }

    private static func cpuTicks() -> [Ticks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { cpu in
            let base = Int(CPU_STATE_MAX) * cpu
            return Ticks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                         system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                         idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                         nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
    }

    private static func cpu(_ start: [Ticks], _ end: [Ticks]) -> WidgetData.CPU? {
        guard !start.isEmpty, start.count == end.count else { return nil }
        var perCore: [Double] = []
        var user = 0.0, system = 0.0, total = 0.0
        for (old, new) in zip(start, end) {
            let u = Double(new.user &- old.user) + Double(new.nice &- old.nice)
            let s = Double(new.system &- old.system)
            let t = u + s + Double(new.idle &- old.idle)
            perCore.append(t > 0 ? (u + s) / t : 0)
            user += u; system += s; total += t
        }
        guard total > 0 else { return nil }
        // On Apple Silicon the efficiency cores come first.
        let efficiency = min(sysctlInt("hw.perflevel1.logicalcpu") ?? 0, perCore.count)
        func average(_ cores: ArraySlice<Double>) -> Double? { cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count) }
        return WidgetData.CPU(total: (user + system) / total, user: user / total, system: system / total,
                              efficiencyAverage: efficiency > 0 ? average(perCore.prefix(efficiency)) : nil,
                              performanceAverage: efficiency > 0 ? average(perCore.dropFirst(efficiency)) : nil,
                              history: [])
    }

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

    private static func disk(read: Double, write: Double) -> WidgetData.Disk? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let block = UInt64(info.f_bsize)
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        return WidgetData.Disk(name: name, free: UInt64(info.f_bavail) * block, total: UInt64(info.f_blocks) * block,
                               readRate: max(read, 0), writeRate: max(write, 0))
    }

    private static func diskCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    // MARK: Network

    /// Bytes of the busiest Wi-Fi/Ethernet interface with an IPv4 address (64-bit counters from NET_RT_IFLIST2).
    private static func networkCounters() -> (received: UInt64, sent: UInt64, interface: String?, address: String?) {
        let addresses = ipv4Addresses()
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0, nil, nil) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0, nil, nil) }
        var best: (received: UInt64, sent: UInt64, interface: String?, address: String?) = (0, 0, nil, nil)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        let bytes = message.ifm_data.ifi_ibytes + message.ifm_data.ifi_obytes
                        if interface.hasPrefix("en"), let address = addresses[interface], bytes > best.received + best.sent {
                            best = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes, interface, address)
                        }
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return best
    }

    private static func ipv4Addresses() -> [String: String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [:] }
        defer { freeifaddrs(list) }
        var result: [String: String] = [:]
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result[String(cString: entry.pointee.ifa_name)] = String(cString: host)
            }
        }
        return result
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

/// Temperatures and fans from the SMC (allowed to the sandboxed extension by an IOKit user-client exception).
struct SMCSample {
    var cpu: Double?
    var cpuMax: Double?
    var gpu: Double?
    var fans: [WidgetData.Fan] = []

    static func read() -> SMCSample {
        let connection = MSSMCOpen()
        guard connection != 0 else { return SMCSample() }
        defer { MSSMCClose(connection) }

        func value(_ key: String) -> Double? {
            var data = MSSMCValue()
            guard MSSMCRead(connection, key, &data) == 0, data.dataSize > 0 else { return nil }
            let bytes = withUnsafeBytes(of: data.bytes) { Array($0.prefix(Int(data.dataSize))) }
            let type = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: data.dataType >> $0) }, encoding: .ascii) ?? ""
            switch type {
            case "flt " where bytes.count >= 4: return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
            case "ui8 ", "si8 ": return Double(bytes[0])
            case "ui16" where bytes.count >= 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            case "fpe2" where bytes.count >= 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
            case "sp78" where bytes.count >= 2: return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
            default: return nil
            }
        }
        func temperatures(_ keys: [String]) -> [Double] { keys.compactMap(value).filter { $0 > 5 && $0 < 130 } }

        var sample = SMCSample()
        if let keys = SMCSensorMap.current {
            let cores = temperatures(keys.cpuCores)
            if !cores.isEmpty { sample.cpu = cores.reduce(0, +) / Double(cores.count); sample.cpuMax = cores.max() }
            let gpu = temperatures(keys.gpu)
            if !gpu.isEmpty { sample.gpu = gpu.reduce(0, +) / Double(gpu.count) }
        }
        let fanCount = Int(value("FNum") ?? 0)
        sample.fans = (0..<min(fanCount, 4)).compactMap { index in
            guard let rpm = value("F\(index)Ac") else { return nil }
            let maximum = value("F\(index)Mx") ?? 0
            return WidgetData.Fan(id: index, rpm: rpm, fraction: maximum > 0 ? min(max(rpm / maximum, 0), 1) : 0)
        }
        return sample
    }
}
