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
            WidgetMessage(element: element, title: "Nessun dato", message: "Impossibile leggere i dati di sistema.")
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
            }
        case .weather:
            if let weather = data.weather {
                WeatherWidget(weather: weather, size: size, time: time, fahrenheit: data.fahrenheit)
            } else {
                WidgetMessage(element: .weather, title: "Meteo non disponibile",
                              message: "Attiva il modulo Meteo in MenuStats: il meteo arriva dall'app.")
            }
        default:
            if let summary = ElementSummary(element: element, data: data) {
                switch size {
                case .small: ElementSmall(summary: summary, time: time)
                case .medium: ElementMedium(summary: summary, time: time)
                }
            } else { missing }
        }
    }

    private var missing: some View {
        WidgetMessage(element: element, title: "Non disponibile", message: "Questo Mac non ha \(element.title.lowercased()) da mostrare.")
    }

    private func timeLabel(_ date: Date) -> String { WidgetFormat.time(date) }
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
            rows = [("Usato", WidgetFormat.storage(disk.total - min(disk.free, disk.total)), WidgetPalette.usage(disk.usedFraction, base: base)),
                    ("Libero", WidgetFormat.storage(disk.free), WidgetPalette.green),
                    ("Totale", WidgetFormat.storage(disk.total), nil),
                    ("Volume", disk.name, nil)]
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
        case .overview, .weather:
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
                        .frame(width: max(2, (proxy.size.width - tip - 7) * CGFloat(min(max(fraction, 0), 1))))
                        .padding(3)
                }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: tip, height: proxy.size.height * 0.38)
            }
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
        WeatherSymbol(name: weather.symbol)
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
