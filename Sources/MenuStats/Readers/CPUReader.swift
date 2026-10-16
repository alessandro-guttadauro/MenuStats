import Darwin

struct CPUStats {
    var total: Double
    var user: Double
    var system: Double
    var perCore: [Double]
    var efficiencyCores: Int
    var performanceCores: Int
    var loadAverage: [Double]
    var brand: String
}

/// CPU usage from per-core tick counters (host_processor_info), as a delta between two samples.
final class CPUReader {
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []
    private let brand = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
    // On Apple Silicon perflevel0 = performance cores, perflevel1 = efficiency cores.
    private let performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
    private let efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0

    func sample() -> CPUStats? {
        guard let current = readTicks() else { return nil }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var perCore: [Double] = []
        var sumUser = 0.0, sumSystem = 0.0, sumTotal = 0.0
        for (old, new) in zip(previous, current) {
            let user = Double(new.user &- old.user) + Double(new.nice &- old.nice)
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let total = user + system + idle
            perCore.append(total > 0 ? (user + system) / total : 0)
            sumUser += user
            sumSystem += system
            sumTotal += total
        }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return CPUStats(
            total: sumTotal > 0 ? (sumUser + sumSystem) / sumTotal : 0,
            user: sumTotal > 0 ? sumUser / sumTotal : 0,
            system: sumTotal > 0 ? sumSystem / sumTotal : 0,
            perCore: perCore,
            efficiencyCores: efficiencyCores,
            performanceCores: performanceCores,
            loadAverage: load,
            brand: brand
        )
    }

    private func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        return (0..<Int(cpuCount)).map { cpu in
            let base = Int(CPU_STATE_MAX) * cpu
            return Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }
}
