import SwiftUI

/// One gauge of the overview: ring, value inside, label below.
private struct OverviewGauge: Identifiable {
    var id: WidgetElement
    var label: String
    var fraction: Double
    var text: String
    var color: Color

    /// Memory, disk and, on Macs that have one, the battery.
    static func all(_ data: WidgetData) -> [OverviewGauge] {
        var gauges: [OverviewGauge] = []
        if let memory = data.memory {
            gauges.append(.init(id: .memory, label: "Memoria", fraction: memory.fraction, text: WidgetFormat.percent(memory.fraction),
                                color: memory.pressure >= 4 ? WidgetPalette.red : memory.pressure >= 2 ? WidgetPalette.orange : WidgetPalette.green))
        }
        if let disk = data.disk {
            gauges.append(.init(id: .disk, label: "Disco", fraction: disk.usedFraction, text: WidgetFormat.percent(disk.usedFraction),
                                color: WidgetPalette.usage(disk.usedFraction, base: WidgetPalette.yellow)))
        }
        if let battery = data.battery {
            gauges.append(.init(id: .battery, label: battery.charging ? "In carica" : "Batteria", fraction: battery.percent,
                                text: WidgetFormat.percent(battery.percent),
                                color: WidgetPalette.battery(battery.percent, charging: battery.charging)))
        }
        return gauges
    }
}

private struct GaugeCell: View {
    var gauge: OverviewGauge
    var diameter: CGFloat
    var lineWidth: CGFloat
    var fontSize: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            LabeledRing(fraction: gauge.fraction, color: gauge.color, text: gauge.text, lineWidth: lineWidth, fontSize: fontSize)
                .frame(width: diameter, height: diameter)
            Text(gauge.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Weather in the overview's free cell: symbol and temperature.
private struct WeatherCell: View {
    var weather: WidgetData.Weather
    var fahrenheit: Bool
    var diameter: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 1) {
                WeatherSymbol(name: weather.symbol).font(.system(size: diameter * 0.36))
                Text(WidgetFormat.temperature(weather.temperature, fahrenheit: fahrenheit))
                    .font(.system(size: diameter * 0.26, weight: .semibold, design: .rounded))
            }
            .frame(width: diameter, height: diameter)
            Text(weather.city).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private func overviewTitle(_ data: WidgetData) -> String {
    (data.chip ?? "Mac").replacingOccurrences(of: "Apple ", with: "")
}

struct OverviewSmall: View {
    var data: WidgetData
    var time: String?

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(element: .overview, title: overviewTitle(data), trailing: time)
            Spacer(minLength: 6)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 8) {
                ForEach(OverviewGauge.all(data)) { GaugeCell(gauge: $0, diameter: 42, lineWidth: 4.5, fontSize: 11) }
                if let weather = data.weather { WeatherCell(weather: weather, fahrenheit: data.fahrenheit, diameter: 42) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct OverviewMedium: View {
    var data: WidgetData
    var time: String?

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(element: .overview, title: overviewTitle(data), trailing: time)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(OverviewGauge.all(data)) { GaugeCell(gauge: $0, diameter: 62, lineWidth: 6.5, fontSize: 14) }
                if let weather = data.weather { WeatherCell(weather: weather, fahrenheit: data.fahrenheit, diameter: 62) }
            }
            Spacer(minLength: 6)
            Text(footer)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }

    /// Free space and battery time, the details behind the rings.
    private var footer: String {
        var parts: [String] = []
        if let disk = data.disk { parts.append("\(WidgetFormat.storage(disk.free)) liberi") }
        if let memory = data.memory { parts.append("\(WidgetFormat.bytes(memory.used)) di \(WidgetFormat.bytes(memory.total))") }
        if let battery = data.battery, let minutes = battery.minutesRemaining {
            parts.append(battery.charging ? "piena tra \(WidgetFormat.duration(minutes: minutes))" : "\(WidgetFormat.duration(minutes: minutes)) di autonomia")
        }
        return parts.joined(separator: " · ")
    }
}
