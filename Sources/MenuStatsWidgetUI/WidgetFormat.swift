import SwiftUI

/// Formatting and colors shared by the desktop widgets and the dropdown's Widget tab.
public enum WidgetFormat {
    public static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }

    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    public static func storage(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    /// Value and unit split, so the number can be large and the unit small ("2.4", "MB/s").
    public static func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(bytesPerSecond, 0)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = (unit > 0 && value < 10) ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return (number, units[unit])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        let parts = rateParts(bytesPerSecond)
        return parts.value + " " + parts.unit
    }

    public static func temperature(_ celsius: Double, fahrenheit: Bool, unit: Bool = false) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: unit ? (fahrenheit ? "%.0f°F" : "%.0f°C") : "%.0f°", value)
    }

    public static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

/// Colors of the widgets, matched to the app's module colors.
public enum WidgetPalette {
    public static let blue = Color(red: 0.20, green: 0.50, blue: 0.88)
    public static let green = Color(red: 0.11, green: 0.66, blue: 0.46)
    public static let yellow = Color(red: 0.93, green: 0.63, blue: 0.0)
    public static let purple = Color(red: 0.42, green: 0.35, blue: 0.86)
    public static let orange = Color(red: 0.92, green: 0.41, blue: 0.20)
    public static let pink = Color(red: 0.89, green: 0.42, blue: 0.60)
    public static let red = Color(red: 0.90, green: 0.25, blue: 0.24)
    public static let cyan = Color(red: 0.18, green: 0.68, blue: 0.86)

    public static func color(_ element: WidgetElement) -> Color {
        switch element {
        case .overview: purple
        case .cpu: blue
        case .memory: green
        case .disk: yellow
        case .network: purple
        case .temperature: orange
        case .fans: pink
        case .battery: green
        case .weather: cyan
        }
    }

    /// Severity tint for a usage fraction: the element's color, then orange and red near the limit.
    public static func usage(_ fraction: Double, base: Color) -> Color {
        fraction >= 0.9 ? red : fraction >= 0.75 ? orange : base
    }

    public static func temperature(_ celsius: Double) -> Color {
        celsius >= 90 ? red : celsius >= 75 ? orange : celsius >= 60 ? yellow : green
    }

    public static func battery(_ fraction: Double, charging: Bool) -> Color {
        charging ? green : fraction <= 0.1 ? red : fraction <= 0.2 ? orange : green
    }

    static let download = blue
    static let upload = orange
}
