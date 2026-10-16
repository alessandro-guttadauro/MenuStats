import CIOKitPrivate
import Foundation

struct FanInfo: Identifiable {
    var id: Int
    var rpm: Double
    var minimum: Double
    var maximum: Double

    var name: String { "Ventola \(id + 1)" }
    var fraction: Double { maximum > 0 ? min(max(rpm / maximum, 0), 1) : 0 }
}

struct SMCStats {
    var fans: [FanInfo]
    /// Total system power draw in watts (SMC key PSTR).
    var systemPower: Double?
    /// Power delivered by the charger in watts (PDTR); nil or 0 on battery.
    var adapterPower: Double?
    /// Per-core CPU temperatures (°C), in the chip's key order. Empty when the chip isn't in `SMCSensorMap`.
    var cpuCoreTemperatures: [Double] = []
    var gpuTemperatures: [Double] = []

    var cpuTemperature: Double? { cpuCoreTemperatures.isEmpty ? nil : cpuCoreTemperatures.reduce(0, +) / Double(cpuCoreTemperatures.count) }
    var cpuTemperatureMax: Double? { cpuCoreTemperatures.max() }
    var gpuTemperature: Double? { gpuTemperatures.isEmpty ? nil : gpuTemperatures.reduce(0, +) / Double(gpuTemperatures.count) }
}

/// SMC temperature keys per chip. "CPU" is the average of the per-core keys, the same figure iStat Menus
/// shows (verified on M3 Pro against its own history: identical to the average of these 11 keys). The HID
/// "PMU tdie" sensors sit elsewhere on the die and read ~5–8 °C lower, so they are only a fallback.
enum SMCSensorMap {
    struct Keys {
        var cpuCores: [String]
        var gpu: [String]
    }

    static let byChip: [String: Keys] = [
        "Apple M3 Pro": Keys(
            cpuCores: ["Tp05", "Tp0D", "Tp0L", "Tp0S", "Tp0V", "Tp0b", "Tp0h", "Tp0n", "Tp0v", "Tp0z", "Tp17"],
            gpu: ["Tg01", "Tg05", "Tg0D", "Tg0L", "Tg0V", "Tg0v", "Tg13", "Tg1B", "Tg1l"]
        ),
        // MacBook Pro (Mac16,8). The per-core `Tp` keys sit at a 40 °C floor while a core idles, so the CPU figure uses
        // the `TfC*` die sensors instead: within ~2 °C of iStat Menus on this Mac (idle 35 vs 36, load 44 vs 42).
        // GPU: the `Tg` sensors that track the GPU cluster (not yet compared with iStat Menus).
        "Apple M4 Pro": Keys(
            cpuCores: ["TfC0", "TfC1", "TfC2", "TfC3", "TfC4"],
            gpu: ["Tg05", "Tg0S", "Tg0Y", "Tg0k", "Tg0z", "Tg1V", "Tg1l"]
        ),
    ]

    static var current: Keys? { Sysctl.string("machdep.cpu.brand_string").flatMap { byChip[$0] } }
}

/// Fans and power from the SMC. Reading works without root; writing (fan control) would need a privileged helper.
final class SMCReader {
    private let connection = MSSMCOpen()
    private lazy var fanCount: Int = read("FNum").map { Int($0) } ?? 0
    /// The chip's table entry, or for chips not listed yet (e.g. M5) the `Tf??` die sensors found on this Mac.
    private lazy var sensorKeys = SMCSensorMap.current ?? discoverDieSensors()

    deinit { MSSMCClose(connection) }

    func sample() -> SMCStats? {
        guard connection != 0 else { return nil }
        let fans = (0..<min(fanCount, 4)).compactMap { index -> FanInfo? in
            guard let rpm = read("F\(index)Ac") else { return nil }
            return FanInfo(id: index, rpm: rpm, minimum: read("F\(index)Mn") ?? 0, maximum: read("F\(index)Mx") ?? 0)
        }
        // Discard unplugged/idle readings outside a plausible range.
        func temperatures(_ keys: [String]) -> [Double] { keys.compactMap(read).filter { $0 > 5 && $0 < 130 } }
        return SMCStats(fans: fans, systemPower: read("PSTR"), adapterPower: read("PDTR"),
                        cpuCoreTemperatures: temperatures(sensorKeys?.cpuCores ?? []),
                        gpuTemperatures: temperatures(sensorKeys?.gpu ?? []))
    }

    /// CPU temperature for chips missing from `SMCSensorMap`: every `Tf??` key that reads a float in a believable
    /// range. Nil (so the HID fallback applies) when the Mac has none. GPU stays on the HID fallback.
    private func discoverDieSensors() -> SMCSensorMap.Keys? {
        guard connection != 0 else { return nil }
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let keys = characters.flatMap { first in characters.map { "Tf\(first)\($0)" } }.filter { key in
            var value = MSSMCValue()
            guard MSSMCRead(connection, key, &value) == 0, fourCC(value.dataType) == "flt ",
                  let degrees = read(key) else { return false }
            return degrees > 20 && degrees < 120
        }
        return keys.isEmpty ? nil : SMCSensorMap.Keys(cpuCores: keys, gpu: [])
    }

    /// Reads a key and decodes the common numeric SMC types.
    private func read(_ key: String) -> Double? {
        var value = MSSMCValue()
        guard MSSMCRead(connection, key, &value) == 0 else { return nil }
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(value.dataSize))) }
        guard !bytes.isEmpty else { return nil }

        switch fourCC(value.dataType) {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "ui8 ", "si8 ":
            return Double(bytes[0])
        case "ui16":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78":
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    private func fourCC(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
    }
}
