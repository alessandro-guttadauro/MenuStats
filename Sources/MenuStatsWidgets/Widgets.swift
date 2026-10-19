import SwiftUI
import WidgetKit

// Desktop and Notification Center widgets (macOS 14+). The extension reads the live values itself (LiveSampler),
// so the widgets work while MenuStats is closed; when the app is running it also reads the snapshot MenuStats
// writes every minute for what the sandbox can't see: per-minute graphs, Apple's battery health, the weather.

struct StatsEntry: TimelineEntry {
    var date: Date
    var data: WidgetData?
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry { StatsEntry(date: Date(), data: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        if context.isPreview {
            completion(StatsEntry(date: Date(), data: WidgetData.load() ?? .sample))
        } else {
            DispatchQueue.global(qos: .userInitiated).async { completion(StatsEntry(date: Date(), data: Self.current())) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let entry = StatsEntry(date: Date(), data: Self.current())
            // macOS treats this as a lower bound and spaces refreshes out to fit its budget.
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
        }
    }

    /// Live values, completed with the app's snapshot where it is recent enough.
    static func current() -> WidgetData {
        var data = LiveSampler.sample()
        let now = Date()
        var graphsFromApp = false
        if let stored = WidgetData.load() {
            let age = now.timeIntervalSince(stored.updated)
            data.fahrenheit = stored.fahrenheit
            if age < 3 * 3600 { data.weather = stored.weather }
            // Apple's official battery health changes slowly: keep it even from an old snapshot.
            if let health = stored.battery?.health, data.battery != nil { data.battery?.health = health }
            if age < 15 * 60 {
                if data.temperature == nil { data.temperature = stored.temperature }
                if data.temperature?.ssd == nil { data.temperature?.ssd = stored.temperature?.ssd }
                if data.fans.isEmpty { data.fans = stored.fans }
                data.cpu?.history = stored.cpu?.history ?? []
                data.memory?.history = stored.memory?.history ?? []
                data.network?.downloadHistory = stored.network?.downloadHistory ?? []
                data.network?.uploadHistory = stored.network?.uploadHistory ?? []
                data.temperature?.history = stored.temperature?.history ?? []
                graphsFromApp = true
            }
        }
        // Without the app, graphs come from the widget's own readings (one per refresh).
        let history = OwnHistory.record(data, at: now)
        if !graphsFromApp, history.count >= 2 {
            data.cpu?.history = history.map(\.cpu)
            data.memory?.history = history.map(\.memory)
            data.network?.downloadHistory = history.map(\.download)
            data.network?.uploadHistory = history.map(\.upload)
            data.temperature?.history = history.compactMap(\.temperature)
        }
        return data
    }
}

/// The last few hours of the widget's own readings, kept in the extension's container.
enum OwnHistory {
    struct Point: Codable {
        var date: Date
        var cpu: Double
        var memory: Double
        var download: Double
        var upload: Double
        var temperature: Double?
    }

    private static let key = "history"

    static func record(_ data: WidgetData, at date: Date) -> [Point] {
        let defaults = UserDefaults.standard
        var points = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Point].self, from: $0) } ?? [])
            .filter { date.timeIntervalSince($0.date) < 6 * 3600 }
        // Several widgets refresh together: one point per minute is enough.
        if points.last.map({ date.timeIntervalSince($0.date) >= 60 }) ?? true {
            points.append(Point(date: date, cpu: data.cpu?.total ?? 0, memory: data.memory?.fraction ?? 0,
                                download: data.network?.download ?? 0, upload: data.network?.upload ?? 0,
                                temperature: data.temperature?.cpu))
            points = Array(points.suffix(48))
            defaults.set(try? JSONEncoder().encode(points), forKey: key)
        }
        return points
    }
}

protocol ElementWidget: Widget {
    static var element: WidgetElement { get }
}

extension ElementWidget {
    var body: some WidgetConfiguration {
        let element = Self.element
        return StaticConfiguration(kind: "MenuStats.\(element.rawValue)", provider: StatsProvider()) { entry in
            SizedWidgetView(element: element, data: entry.data)
        }
        .configurationDisplayName(element == .overview ? "MenuStats" : element.title)
        .description(element.summary)
        .supportedFamilies(element.sizes.map(\.family))
        // Our own margins, the same in every family and in the previews in Settings.
        .contentMarginsDisabled()
    }
}

struct SizedWidgetView: View {
    var element: WidgetElement
    var data: WidgetData?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        MenuStatsWidgetView(element: element, size: WidgetSize(family), data: data)
            .padding(WidgetMetrics.margin)
            .containerBackground(for: .widget) { WidgetBackground(element: element) }
    }
}

extension WidgetSize {
    var family: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        }
    }

    init(_ family: WidgetFamily) {
        switch family {
        case .systemMedium: self = .medium
        case .systemLarge, .systemExtraLarge: self = .large
        default: self = .small
        }
    }
}

struct OverviewWidget: ElementWidget { static let element = WidgetElement.overview }
struct CPUWidget: ElementWidget { static let element = WidgetElement.cpu }
struct MemoryWidget: ElementWidget { static let element = WidgetElement.memory }
struct DiskWidget: ElementWidget { static let element = WidgetElement.disk }
struct NetworkElementWidget: ElementWidget { static let element = WidgetElement.network }
struct TemperatureWidget: ElementWidget { static let element = WidgetElement.temperature }
struct FansWidget: ElementWidget { static let element = WidgetElement.fans }
struct BatteryWidget: ElementWidget { static let element = WidgetElement.battery }
struct WeatherElementWidget: ElementWidget { static let element = WidgetElement.weather }

@main
struct MenuStatsWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        CPUWidget()
        MemoryWidget()
        DiskWidget()
        NetworkElementWidget()
        TemperatureWidget()
        FansWidget()
        BatteryWidget()
        WeatherElementWidget()
    }
}
