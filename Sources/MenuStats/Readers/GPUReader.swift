import Foundation
import IOKit

struct GPUStats {
    /// Busy fraction of the GPU (0…1), from the driver's own counter.
    var utilization: Double
    /// Rendering and tiling stages, when the driver reports them.
    var renderer: Double?
    var tiler: Double?
    var name: String?
}

/// GPU load from the IOAccelerator's `PerformanceStatistics` (the counter Activity Monitor's GPU History uses).
/// No privileges needed. The Neural Engine has no such public counter: only `powermetrics` (root) reports it.
enum GPUReader {
    static func sample() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: GPUStats?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard result == nil,
                  let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? [String: Any],
                  let device = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            result = GPUStats(
                utilization: min(max(device / 100, 0), 1),
                renderer: (stats["Renderer Utilization %"] as? NSNumber).map { $0.doubleValue / 100 },
                tiler: (stats["Tiler Utilization %"] as? NSNumber).map { $0.doubleValue / 100 },
                name: (model as? String) ?? (model as? Data).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .controlCharacters) }
            )
        }
        return result
    }
}
