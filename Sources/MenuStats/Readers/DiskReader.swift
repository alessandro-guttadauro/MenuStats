import Foundation
import IOKit

struct DiskStats {
    var total: UInt64
    /// Truly free space on the startup volume.
    var free: UInt64
    /// Free plus space macOS can purge on demand.
    var available: UInt64
    var readRate: Double
    var writeRate: Double

    var usedFraction: Double { total > 0 ? Double(total - min(free, total)) / Double(total) : 0 }
    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }
}

/// Startup volume space plus read/write throughput summed over every IOBlockStorageDriver.
final class DiskReader {
    private var previous: (read: UInt64, write: UInt64, time: Double)?
    // Volume capacity is a slow file system call and changes slowly: refresh it every 10 s.
    private var space: (total: UInt64, free: UInt64, available: UInt64, time: Double)?

    func sample() -> DiskStats? {
        let (read, write) = readIOCounters()
        let now = uptimeSeconds()
        defer { previous = (read, write, now) }

        var readRate = 0.0, writeRate = 0.0
        if let previous, now > previous.time, read >= previous.read, write >= previous.write {
            readRate = Double(read - previous.read) / (now - previous.time)
            writeRate = Double(write - previous.write) / (now - previous.time)
        }

        if space == nil || now - space!.time > 10 {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
            let free = UInt64(values?.volumeAvailableCapacity ?? 0)
            space = (UInt64(values?.volumeTotalCapacity ?? 0), free,
                     max(UInt64(max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0)), free), now)
        }
        return DiskStats(
            total: space!.total,
            free: space!.free,
            available: space!.available,
            readRate: readRate,
            writeRate: writeRate
        )
    }

    private func readIOCounters() -> (read: UInt64, write: UInt64) {
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
}
