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
}

/// Fans and power from the SMC. Reading works without root; writing (fan control) would need a privileged helper.
final class SMCReader {
    private let connection = MSSMCOpen()
    private lazy var fanCount: Int = read("FNum").map { Int($0) } ?? 0

    deinit { MSSMCClose(connection) }

    func sample() -> SMCStats? {
        guard connection != 0 else { return nil }
        let fans = (0..<min(fanCount, 4)).compactMap { index -> FanInfo? in
            guard let rpm = read("F\(index)Ac") else { return nil }
            return FanInfo(id: index, rpm: rpm, minimum: read("F\(index)Mn") ?? 0, maximum: read("F\(index)Mx") ?? 0)
        }
        return SMCStats(fans: fans, systemPower: read("PSTR"), adapterPower: read("PDTR"))
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
