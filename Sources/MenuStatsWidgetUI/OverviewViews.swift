import SwiftUI

/// One gauge of the overview: ring, value inside, label below.
private struct OverviewGauge: Identifiable {
    var id: WidgetElement
    var label: String
    var fraction: Double
    var text: String
    var color: Color

    /// CPU, memory, disk and then battery (or the CPU temperature on Macs without one).
    static func main(_ data: WidgetData) -> [OverviewGauge] {
        var gauges: [OverviewGauge] = []
        if let cpu = data.cpu {
            gauges.append(.init(id: .cpu, label: "CPU", fraction: cpu.total, text: WidgetFormat.percent(cpu.total),
                                color: WidgetPalette.usage(cpu.total, base: WidgetPalette.blue)))
        }
        if let memory = data.memory {
            gauges.append(.init(id: .memory, label: "Memoria", fraction: memory.fraction, text: WidgetFormat.percent(memory.fraction),
                                color: memory.pressure >= 4 ? WidgetPalette.red : memory.pressure >= 2 ? WidgetPalette.orange : WidgetPalette.green))
        }
        if let disk = data.disk {
            gauges.append(.init(id: .disk, label: "Disco", fraction: disk.usedFraction, text: WidgetFormat.percent(disk.usedFraction),
                                color: WidgetPalette.usage(disk.usedFraction, base: WidgetPalette.yellow)))
        }
        if let battery = data.battery {
            gauges.append(.init(id: .battery, label: "Batteria", fraction: battery.percent, text: WidgetFormat.percent(battery.percent),
                                color: WidgetPalette.battery(battery.percent, charging: battery.charging)))
        } else if let celsius = data.temperature?.cpu {
            gauges.append(.init(id: .temperature, label: "CPU", fraction: min(max((celsius - 20) / 80, 0), 1),
                                text: WidgetFormat.temperature(celsius, fahrenheit: data.fahrenheit), color: WidgetPalette.temperature(celsius)))
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
            HStack(spacing: 3) {
                if gauge.id == .battery { Image(systemName: "battery.75percent").font(.system(size: 8)) }
                Text(gauge.label).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small strip with an icon and a value (network, temperature, fans…).
private struct InfoChip: View {
    var symbol: String
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

private func overviewTitle(_ data: WidgetData) -> String {
    (data.chip ?? "Mac").replacingOccurrences(of: "Apple ", with: "")
}

struct OverviewSmall: View {
    var data: WidgetData
    var time: String?

    var body: some View {
        let gauges = OverviewGauge.main(data)
        VStack(spacing: 0) {
            WidgetHeader(element: .overview, title: overviewTitle(data), trailing: time)
            Spacer(minLength: 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(gauges) { GaugeCell(gauge: $0, diameter: 42, lineWidth: 4.5, fontSize: 11) }
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
                ForEach(OverviewGauge.main(data)) { GaugeCell(gauge: $0, diameter: 60, lineWidth: 6, fontSize: 14) }
            }
            Spacer(minLength: 8)
            OverviewChips(data: data)
        }
    }
}

/// Network, temperature and fan speed in one row.
private struct OverviewChips: View {
    var data: WidgetData

    var body: some View {
        HStack(spacing: 10) {
            if let network = data.network {
                InfoChip(symbol: "arrow.down", text: WidgetFormat.rate(network.download), color: WidgetPalette.download)
                InfoChip(symbol: "arrow.up", text: WidgetFormat.rate(network.upload), color: WidgetPalette.upload)
            }
            Spacer(minLength: 0)
            if let celsius = data.temperature?.cpu, data.battery != nil {
                InfoChip(symbol: "thermometer.medium", text: WidgetFormat.temperature(celsius, fahrenheit: data.fahrenheit),
                         color: WidgetPalette.temperature(celsius))
            }
            if let fan = data.fans.max(by: { $0.rpm < $1.rpm }) {
                InfoChip(symbol: "fan", text: String(format: "%.0f rpm", fan.rpm), color: WidgetPalette.pink)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct OverviewLarge: View {
    var data: WidgetData
    var time: String?

    var body: some View {
        VStack(spacing: 10) {
            WidgetHeader(element: .overview, title: overviewTitle(data), trailing: time)
            HStack(spacing: 4) {
                ForEach(OverviewGauge.main(data)) { GaugeCell(gauge: $0, diameter: 62, lineWidth: 6.5, fontSize: 14) }
            }
            if let cpu = data.cpu {
                Panel(title: "CPU", symbol: "cpu", color: WidgetPalette.blue,
                      trailing: "Utente \(WidgetFormat.percent(cpu.user)) · Sistema \(WidgetFormat.percent(cpu.system))") {
                    Sparkline(values: cpu.history, color: WidgetPalette.usage(cpu.total, base: WidgetPalette.blue), maximum: 1)
                }
            }
            if let network = data.network {
                let peak = max((network.downloadHistory + network.uploadHistory).max() ?? 1, 1)
                Panel(title: "Rete", symbol: "network", color: WidgetPalette.purple,
                      trailing: "↓ \(WidgetFormat.rate(network.download))  ↑ \(WidgetFormat.rate(network.upload))") {
                    ZStack {
                        Sparkline(values: network.downloadHistory, color: WidgetPalette.download, maximum: peak)
                        Sparkline(values: network.uploadHistory, color: WidgetPalette.upload, maximum: peak, filled: false)
                    }
                }
            }
            bottomRow
        }
    }

    /// Temperatures, fans, battery details and weather, whichever this Mac has.
    private var bottomRow: some View {
        HStack(spacing: 8) {
            if let temperature = data.temperature, let cpu = temperature.cpu {
                Tile(symbol: "thermometer.medium", color: WidgetPalette.temperature(cpu), title: "Temperatura",
                     value: WidgetFormat.temperature(cpu, fahrenheit: data.fahrenheit, unit: true),
                     detail: temperature.gpu.map { "GPU " + WidgetFormat.temperature($0, fahrenheit: data.fahrenheit) })
            }
            if let fan = data.fans.max(by: { $0.rpm < $1.rpm }) {
                Tile(symbol: "fan", color: WidgetPalette.pink, title: "Ventole", value: String(format: "%.0f", fan.rpm),
                     detail: fan.rpm > 0 ? "rpm · \(WidgetFormat.percent(fan.fraction))" : "ferme")
            }
            if let weather = data.weather {
                Tile(symbol: weather.symbol, color: WidgetPalette.cyan, title: weather.city,
                     value: WidgetFormat.temperature(weather.temperature, fahrenheit: data.fahrenheit), detail: weather.condition, multicolor: true)
            } else if let battery = data.battery {
                Tile(symbol: battery.charging ? "battery.100percent.bolt" : "battery.75percent",
                     color: WidgetPalette.battery(battery.percent, charging: battery.charging), title: "Batteria",
                     value: WidgetFormat.percent(battery.percent),
                     detail: battery.health.map { "Salute \(WidgetFormat.percent($0))" })
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Titled chart box of the large overview.
private struct Panel<Chart: View>: View {
    var title: String
    var symbol: String
    var color: Color
    var trailing: String
    @ViewBuilder var chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(trailing).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            chart.frame(maxHeight: .infinity)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct Tile: View {
    var symbol: String
    var color: Color
    var title: String
    var value: String
    var detail: String?
    var multicolor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .symbolRenderingMode(multicolor ? .multicolor : .monochrome)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
