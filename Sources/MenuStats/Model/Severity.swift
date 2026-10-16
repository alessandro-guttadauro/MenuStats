import AppKit
import SwiftUI

/// How much attention a module needs. Drives the automatic alert colors: yellow → orange → red as danger grows.
enum Severity: Int, Comparable {
    case positive = -1 // good news worth showing (battery charging)
    case normal = 0
    case elevated
    case high
    case critical

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    var nsColor: NSColor? {
        switch self {
        case .positive: .systemGreen
        case .normal: nil
        case .elevated: .systemYellow
        case .high: .systemOrange
        case .critical: .systemRed
        }
    }

    var color: Color? { nsColor.map(Color.init(nsColor:)) }

    var label: String {
        switch self {
        case .positive: "In carica"
        case .normal: "Normale"
        case .elevated: "Attenzione"
        case .high: "Alto"
        case .critical: "Critico"
        }
    }

    /// Severity of a module for the current snapshot, using the user's thresholds where they exist.
    static func of(_ module: ModuleID, snapshot: Snapshot, cpuBusy: Double, temperatureHot: Double, source: SensorSource) -> Severity {
        switch module {
        case .cpu:
            guard let total = snapshot.cpu?.total else { return .normal }
            if total >= max(0.95, cpuBusy) { return .critical }
            if total >= cpuBusy { return .high }
            if total >= cpuBusy - 0.2 { return .elevated }
            return .normal

        case .memory:
            guard let memory = snapshot.memory else { return .normal }
            if memory.pressureLevel >= 4 { return .critical }
            if memory.pressureLevel >= 2 { return .high }
            if memory.usedFraction >= 0.9 { return .elevated }
            return .normal

        case .disk:
            guard let disk = snapshot.disk, disk.total > 0 else { return .normal }
            if disk.freeFraction < 0.05 { return .critical }
            if disk.freeFraction < 0.10 { return .high }
            if disk.freeFraction < 0.15 { return .elevated }
            return .normal

        case .network:
            return snapshot.network?.interface == nil ? .elevated : .normal

        case .sensors:
            let celsius: Double? = switch source {
            case .cpuAverage: snapshot.sensors.cpuAverage
            case .cpuMax: snapshot.sensors.cpuMax
            case .hottest: snapshot.sensors.hottest?.celsius
            case .ssd: snapshot.ssdTemperature
            case .battery: snapshot.battery?.temperature ?? snapshot.sensors.batteryTemperature
            }
            var level = Severity.normal
            if let celsius {
                if celsius >= temperatureHot + 10 { level = .critical }
                else if celsius >= temperatureHot { level = .high }
                else if celsius >= temperatureHot - 10 { level = .elevated }
            }
            // macOS's own thermal state wins when it is worse (it throttles the Mac).
            let thermal: Severity = switch snapshot.thermalState {
            case .critical: .critical
            case .serious: .high
            case .fair: .elevated
            default: .normal
            }
            return max(level, thermal)

        case .fans:
            let fraction = snapshot.smc?.fans.map(\.fraction).max() ?? 0
            if fraction >= 0.85 { return .critical }
            if fraction >= 0.6 { return .high }
            if fraction >= 0.35 { return .elevated }
            return .normal

        case .battery:
            guard let battery = snapshot.battery else { return .normal }
            if battery.isCharging { return .positive }
            if battery.onACPower { return .normal }
            if battery.percent <= 0.1 { return .critical }
            if battery.percent <= 0.2 { return .high }
            if battery.percent <= 0.3 { return .elevated }
            return .normal
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)),
                      Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
    }
}
