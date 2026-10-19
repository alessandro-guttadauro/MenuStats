import Darwin

/// SMC temperature keys per chip, shared by the app and the widget extension. "CPU" is the average of the
/// per-core keys, the same figure iStat Menus shows (verified on M3 Pro against its own history: identical to the
/// average of these 11 keys). The HID "PMU tdie" sensors sit elsewhere on the die and read ~5–8 °C lower, so they
/// are only a fallback.
public enum SMCSensorMap {
    public struct Keys {
        public var cpuCores: [String]
        public var gpu: [String]
        public init(cpuCores: [String], gpu: [String]) { self.cpuCores = cpuCores; self.gpu = gpu }
    }

    public static let byChip: [String: Keys] = [
        "Apple M3 Pro": Keys(
            cpuCores: ["Tp05", "Tp0D", "Tp0L", "Tp0S", "Tp0V", "Tp0b", "Tp0h", "Tp0n", "Tp0v", "Tp0z", "Tp17"],
            gpu: ["Tg01", "Tg05", "Tg0D", "Tg0L", "Tg0V", "Tg0v", "Tg13", "Tg1B", "Tg1l"]
        ),
        // MacBook Pro (Mac16,8). The per-core `Tp` keys sit at a 40 °C floor while a core idles, so the CPU figure uses
        // the `TfC*` die sensors instead: within ~2 °C of iStat Menus on this Mac (idle 35 vs 36, load 44 vs 42).
        // GPU: the `Tg` sensors that track the GPU cluster (idle: 46-47 vs 46.8 in iStat Menus).
        "Apple M4 Pro": Keys(
            cpuCores: ["TfC0", "TfC1", "TfC2", "TfC3", "TfC4"],
            gpu: ["Tg05", "Tg0S", "Tg0Y", "Tg0k", "Tg0z", "Tg1V", "Tg1l"]
        ),
    ]

    /// "Apple M3 Pro", from `machdep.cpu.brand_string`.
    public static let chip: String? = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()

    public static var current: Keys? { chip.flatMap { byChip[$0] } }
}
