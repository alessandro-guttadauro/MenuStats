import Darwin
import Foundation

enum Sysctl {
    /// Reads an integer sysctl of any width (int32 or int64) by name.
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }
}

extension Sysctl {
    /// Seconds since boot, including time asleep (what `uptime` and Activity Monitor show).
    static func secondsSinceBoot() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - (TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1e6)
    }
}

/// Monotonic seconds (stops during sleep), used to turn counter deltas into per-second rates.
func uptimeSeconds() -> Double {
    ProcessInfo.processInfo.systemUptime
}
