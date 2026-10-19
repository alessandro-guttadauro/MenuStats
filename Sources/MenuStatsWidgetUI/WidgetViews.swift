import SwiftUI

/// Entry point for every widget: one element (or the overview) at a given size.
/// Used by the WidgetKit extension and, with live data, by the dropdown's Widget tab.
public struct MenuStatsWidgetView: View {
    var element: WidgetElement
    var size: WidgetSize
    var data: WidgetData?
    /// Desktop widgets show when the data was written; the live dropdown doesn't need it.
    var showsTime: Bool

    public init(element: WidgetElement, size: WidgetSize, data: WidgetData?, showsTime: Bool = true) {
        self.element = element; self.size = size; self.data = data; self.showsTime = showsTime
    }

    public var body: some View {
        if let data {
            content(data)
        } else {
            WidgetMessage(element: element, title: "Nessun dato",
                          message: "Avvia MenuStats: i widget si aggiornano mentre l'app è aperta.")
        }
    }

    @ViewBuilder
    private func content(_ data: WidgetData) -> some View {
        let time = showsTime ? timeLabel(data.updated) : nil
        switch element {
        case .overview:
            switch size {
            case .small: OverviewSmall(data: data, time: time)
            case .medium: OverviewMedium(data: data, time: time)
            case .large: OverviewLarge(data: data, time: time)
            }
        case .network:
            if let network = data.network {
                NetworkWidget(network: network, size: size, time: time)
            } else { missing }
        case .weather:
            if let weather = data.weather {
                WeatherWidget(weather: weather, size: size, time: time, fahrenheit: data.fahrenheit)
            } else {
                WidgetMessage(element: .weather, title: "Meteo spento",
                              message: "Attiva il modulo Meteo nelle impostazioni di MenuStats.")
            }
        default:
            if let summary = ElementSummary(element: element, data: data) {
                switch size {
                case .small: ElementSmall(summary: summary, time: time)
                default: ElementMedium(summary: summary, time: time)
                }
            } else { missing }
        }
    }

    private var missing: some View {
        WidgetMessage(element: element, title: "Non disponibile", message: "Questo Mac non ha \(element.title.lowercased()) da mostrare.")
    }

    /// Time of the data, in orange when it is old (MenuStats closed or the Mac asleep).
    private func timeLabel(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        return age > 20 * 60 ? "⚠︎ " + WidgetFormat.time(date) : WidgetFormat.time(date)
    }
}

struct WidgetMessage: View {
    var element: WidgetElement
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(element: element)
            Spacer(minLength: 0)
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Single elements

/// What a single-element widget shows, derived from the snapshot.
struct ElementSummary {
    var element: WidgetElement
    var value: String
    var unit: String
    var caption: String
    /// Gauge fill, nil when the element has none.
    var fraction: Double?
    var color: Color
    var history: [Double]
    var historyMaximum: Double?
    var historyMinimum: Double?
    var rows: [(label: String, value: String, color: Color?)]
    var bar: [(fraction: Double, color: Color)]?
    /// Text inside the medium widget's ring when it differs from the big value (disk: used %).
    var gaugeLabel: String?

    init?(element: WidgetElement, data: WidgetData) {
        self.element = element
        let base = WidgetPalette.color(element)
        bar = nil
        gaugeLabel = nil
        historyMaximum = nil
        historyMinimum = nil
        switch element {
        case .cpu:
            guard let cpu = data.cpu else { return nil }
            value = String(format: "%.0f", cpu.total * 100); unit = "%"
            caption = "Utente \(WidgetFormat.percent(cpu.user)) · Sistema \(WidgetFormat.percent(cpu.system))"
            fraction = cpu.total
            color = WidgetPalette.usage(cpu.total, base: base)
            history = cpu.history; historyMaximum = 1
            rows = [("Utente", WidgetFormat.percent(cpu.user), WidgetPalette.blue),
                    ("Sistema", WidgetFormat.percent(cpu.system), WidgetPalette.orange)]
            if let performance = cpu.performanceAverage { rows.append(("Core P", WidgetFormat.percent(performance), nil)) }
            if let efficiency = cpu.efficiencyAverage { rows.append(("Core E", WidgetFormat.percent(efficiency), nil)) }
        case .memory:
            guard let memory = data.memory else { return nil }
            value = String(format: "%.0f", memory.fraction * 100); unit = "%"
            caption = "\(WidgetFormat.bytes(memory.used)) di \(WidgetFormat.bytes(memory.total))"
            fraction = memory.fraction
            let pressureColor = memory.pressure >= 4 ? WidgetPalette.red : memory.pressure >= 2 ? WidgetPalette.orange : base
            color = pressureColor
            history = memory.history; historyMaximum = 1
            let total = Double(max(memory.total, 1))
            rows = [("App", WidgetFormat.bytes(memory.app), WidgetPalette.blue),
                    ("Wired", WidgetFormat.bytes(memory.wired), WidgetPalette.orange),
                    ("Compressa", WidgetFormat.bytes(memory.compressed), WidgetPalette.pink),
                    ("Pressione", memory.pressure >= 4 ? "Critica" : memory.pressure >= 2 ? "Alta" : "Normale", nil)]
            bar = [(Double(memory.app) / total, WidgetPalette.blue), (Double(memory.wired) / total, WidgetPalette.orange),
                   (Double(memory.compressed) / total, WidgetPalette.pink)]
        case .disk:
            guard let disk = data.disk else { return nil }
            let gigabytes = Double(disk.free) / 1e9
            if gigabytes >= 1000 { value = String(format: "%.1f", gigabytes / 1000); unit = "TB" } else {
                value = String(format: gigabytes >= 10 ? "%.0f" : "%.1f", gigabytes); unit = "GB"
            }
            caption = "liberi di \(WidgetFormat.storage(disk.total)) · \(WidgetFormat.percent(disk.usedFraction)) usato"
            gaugeLabel = WidgetFormat.percent(disk.usedFraction)
            fraction = disk.usedFraction
            color = WidgetPalette.usage(disk.usedFraction, base: base)
            history = []
            rows = [("Lettura", WidgetFormat.rate(disk.readRate), WidgetPalette.blue),
                    ("Scrittura", WidgetFormat.rate(disk.writeRate), WidgetPalette.orange),
                    ("Volume", disk.name, nil)]
        case .temperature:
            guard let temperature = data.temperature, let cpu = temperature.cpu else { return nil }
            value = WidgetFormat.temperature(cpu, fahrenheit: data.fahrenheit); unit = ""
            caption = ["Termica nominale", "Termica moderata", "Termica elevata", "Termica critica"][min(max(temperature.thermalState, 0), 3)]
            fraction = min(max((cpu - 20) / 80, 0), 1)
            color = WidgetPalette.temperature(cpu)
            history = temperature.history; historyMinimum = (temperature.history.min() ?? 30) - 3; historyMaximum = (temperature.history.max() ?? 60) + 3
            rows = [("CPU", WidgetFormat.temperature(cpu, fahrenheit: data.fahrenheit, unit: true), WidgetPalette.temperature(cpu))]
            if let maximum = temperature.cpuMax { rows.append(("Core più caldo", WidgetFormat.temperature(maximum, fahrenheit: data.fahrenheit, unit: true), nil)) }
            if let gpu = temperature.gpu { rows.append(("GPU", WidgetFormat.temperature(gpu, fahrenheit: data.fahrenheit, unit: true), WidgetPalette.temperature(gpu))) }
            if let ssd = temperature.ssd { rows.append(("SSD", WidgetFormat.temperature(ssd, fahrenheit: data.fahrenheit, unit: true), WidgetPalette.temperature(ssd))) }
        case .fans:
            guard !data.fans.isEmpty else { return nil }
            let fastest = data.fans.max { $0.rpm < $1.rpm }!
            value = String(format: "%.0f", fastest.rpm); unit = "rpm"
            caption = fastest.rpm > 0 ? "\(WidgetFormat.percent(fastest.fraction)) della velocità massima" : "Ventole ferme"
            fraction = fastest.fraction
            color = WidgetPalette.usage(fastest.fraction, base: base)
            history = []
            rows = data.fans.map { ("Ventola \($0.id + 1)", String(format: "%.0f rpm · %.0f%%", $0.rpm, $0.fraction * 100), nil) }
        case .battery:
            guard let battery = data.battery else { return nil }
            value = String(format: "%.0f", battery.percent * 100); unit = "%"
            if battery.charging {
                caption = battery.minutesRemaining.map { "Carica · piena tra \(WidgetFormat.duration(minutes: $0))" } ?? "In carica"
            } else if battery.pluggedIn {
                caption = "Collegato all'alimentazione"
            } else {
                caption = battery.minutesRemaining.map { "\(WidgetFormat.duration(minutes: $0)) rimanenti" } ?? "A batteria"
            }
            fraction = battery.percent
            color = WidgetPalette.battery(battery.percent, charging: battery.charging)
            history = []
            rows = []
            if let health = battery.health { rows.append(("Salute", WidgetFormat.percent(health), nil)) }
            if let cycles = battery.cycles { rows.append(("Cicli", "\(cycles)", nil)) }
            if let watts = battery.watts, abs(watts) >= 0.1 {
                rows.append((watts > 0 ? "In ingresso" : "Consumo", String(format: "%.1f W", abs(watts)), nil))
            }
        case .overview, .network, .weather:
            return nil
        }
    }

    var gaugeText: String { unit == "%" ? value + "%" : value }
}

struct ElementSmall: View {
    var summary: ElementSummary
    var time: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(element: summary.element, trailing: time)
            Spacer(minLength: 4)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    BigValue(value: summary.value, unit: summary.unit, size: 30)
                    Text(summary.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let fraction = summary.fraction, summary.element != .battery {
                    WidgetRing(fraction: fraction, color: summary.color, lineWidth: 5).frame(width: 34, height: 34)
                }
            }
            Spacer(minLength: 6)
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if summary.history.count >= 2 {
            Sparkline(values: summary.history, color: summary.color, maximum: summary.historyMaximum, minimum: summary.historyMinimum)
                .frame(height: 34)
        } else if let bar = summary.bar {
            SegmentedBar(parts: bar)
        } else if summary.element == .battery, let fraction = summary.fraction {
            BatteryShape(fraction: fraction, color: summary.color).frame(height: 26)
        } else if let fraction = summary.fraction {
            CapsuleBar(fraction: fraction, color: summary.color, height: 8)
        }
    }
}

struct ElementMedium: View {
    var summary: ElementSummary
    var time: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(element: summary.element)
                Spacer(minLength: 6)
                gauge.frame(width: 84, height: 84).frame(maxWidth: .infinity)
                Spacer(minLength: 6)
                Text(summary.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 118)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Spacer()
                    if let time { Text(time).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                }
                .frame(height: 14)
                ForEach(Array(summary.rows.prefix(4).enumerated()), id: \.offset) { _, row in
                    StatRow(label: row.label, value: row.value, color: row.color)
                }
                Spacer(minLength: 4)
                if summary.history.count >= 2 {
                    Sparkline(values: summary.history, color: summary.color, maximum: summary.historyMaximum, minimum: summary.historyMinimum)
                        .frame(height: 34)
                } else if let bar = summary.bar {
                    SegmentedBar(parts: bar)
                } else if let fraction = summary.fraction, summary.element != .battery {
                    CapsuleBar(fraction: fraction, color: summary.color, height: 8)
                }
            }
        }
    }

    @ViewBuilder
    private var gauge: some View {
        if summary.element == .battery, let fraction = summary.fraction {
            VStack(spacing: 6) {
                BigValue(value: summary.value, unit: "%", size: 28)
                BatteryShape(fraction: fraction, color: summary.color).frame(width: 74, height: 30)
            }
        } else {
            LabeledRing(fraction: summary.fraction ?? 0, color: summary.color,
                        text: summary.gaugeLabel ?? (summary.unit == "%" ? summary.gaugeText : summary.value),
                        lineWidth: 8, fontSize: summary.value.count > 4 ? 17 : 21)
        }
    }
}

/// Battery outline filled to `fraction`.
struct BatteryShape: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let tip = max(3, proxy.size.width * 0.05)
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: proxy.size.height * 0.28)
                        .stroke(Color.primary.opacity(0.35), lineWidth: 1.5)
                    RoundedRectangle(cornerRadius: proxy.size.height * 0.18)
                        .fill(color)
                        .frame(width: max(2, (proxy.size.width - tip - 7) * min(max(fraction, 0), 1)))
                        .padding(3)
                }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: tip, height: proxy.size.height * 0.38)
            }
        }
    }
}

// MARK: - Network

struct NetworkWidget: View {
    var network: WidgetData.Network
    var size: WidgetSize
    var time: String?

    private var peak: Double { max((network.downloadHistory + network.uploadHistory).max() ?? 1, 1) }

    var body: some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(element: .network, trailing: time)
                Spacer(minLength: 4)
                rate(arrow: "arrow.down", value: network.download, color: WidgetPalette.download, size: 22)
                rate(arrow: "arrow.up", value: network.upload, color: WidgetPalette.upload, size: 16)
                Spacer(minLength: 6)
                chart.frame(height: 30)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(element: .network)
                    Spacer(minLength: 2)
                    rate(arrow: "arrow.down", value: network.download, color: WidgetPalette.download, size: 26)
                    rate(arrow: "arrow.up", value: network.upload, color: WidgetPalette.upload, size: 20)
                    Spacer(minLength: 2)
                    Text([network.interface, network.address].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 128, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(time == nil ? "Ultimi minuti" : "Ultima ora").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        if let time { Text(time).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                    }
                    chart
                    HStack {
                        legend("Download", WidgetPalette.download)
                        legend("Upload", WidgetPalette.upload)
                        Spacer()
                        Text("picco \(WidgetFormat.rate(peak))").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var chart: some View {
        ZStack {
            Sparkline(values: network.downloadHistory, color: WidgetPalette.download, maximum: peak)
            Sparkline(values: network.uploadHistory, color: WidgetPalette.upload, maximum: peak, filled: false)
        }
    }

    private func rate(arrow: String, value: Double, color: Color, size: CGFloat) -> some View {
        let parts = WidgetFormat.rateParts(value)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: arrow).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(color)
            BigValue(value: parts.value, unit: parts.unit, size: size)
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Weather

struct WeatherWidget: View {
    var weather: WidgetData.Weather
    var size: WidgetSize
    var time: String?
    var fahrenheit: Bool

    var body: some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(element: .weather, title: weather.city, trailing: time)
                Spacer(minLength: 2)
                HStack(alignment: .center) {
                    BigValue(value: WidgetFormat.temperature(weather.temperature, fahrenheit: fahrenheit), size: 38)
                    Spacer(minLength: 0)
                    symbol.font(.system(size: 30))
                }
                Spacer(minLength: 2)
                Text(weather.condition).font(.system(size: 11, weight: .medium)).lineLimit(1)
                range.padding(.top, 2)
            }
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    WidgetHeader(element: .weather, title: weather.city)
                    Spacer(minLength: 2)
                    BigValue(value: WidgetFormat.temperature(weather.temperature, fahrenheit: fahrenheit), size: 46)
                    Spacer(minLength: 2)
                    Text(weather.condition).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    range.padding(.top, 2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing) {
                    if let time { Text(time).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    symbol.font(.system(size: 58))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var symbol: some View {
        Image(systemName: weather.symbol).symbolRenderingMode(.multicolor)
    }

    @ViewBuilder
    private var range: some View {
        if let high = weather.high, let low = weather.low {
            Text("Max \(WidgetFormat.temperature(high, fahrenheit: fahrenheit))  Min \(WidgetFormat.temperature(low, fahrenheit: fahrenheit))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
