import Darwin

struct MemoryStats {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int

    /// "Used" as Activity Monitor computes it: app + wired + compressed.
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Memory breakdown from host_statistics64(HOST_VM_INFO64).
final class MemoryReader {
    private let total = UInt64(Sysctl.int("hw.memsize") ?? 0)

    func sample() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let free = UInt64(stats.free_count) * page

        let swap = Sysctl.swapUsage()

        return MemoryStats(
            total: total,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: free,
            swapUsed: swap?.xsu_used ?? 0,
            swapTotal: swap?.xsu_total ?? 0,
            pressureLevel: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        )
    }
}
