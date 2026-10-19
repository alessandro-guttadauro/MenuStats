import SwiftUI
import WidgetKit

// Desktop and Notification Center widgets (macOS 14+) for values that change slowly: memory, disk, battery, weather.
// The extension reads memory, disk and battery itself (LiveSampler), so the widgets work while MenuStats is closed;
// it also reads the snapshot MenuStats writes every minute for the memory graph, Apple's battery health and the weather.

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

    /// Live values, completed with the app's snapshot.
    static func current() -> WidgetData {
        var data = LiveSampler.sample()
        let now = Date()
        var graphFromApp = false
        if let stored = WidgetData.load() {
            let age = now.timeIntervalSince(stored.updated)
            data.fahrenheit = stored.fahrenheit
            if age < 3 * 3600 { data.weather = stored.weather }
            // Apple's official battery health changes slowly: keep it even from an old snapshot.
            if let health = stored.battery?.health, data.battery != nil { data.battery?.health = health }
            if age < 15 * 60, let history = stored.memory?.history, history.count >= 2 {
                data.memory?.history = history
                graphFromApp = true
            }
        }
        // Without the app, the memory graph comes from the widget's own readings (one per refresh).
        let history = OwnHistory.record(data, at: now)
        if !graphFromApp, history.count >= 2 { data.memory?.history = history.map(\.memory) }
        return data
    }
}

/// The last few hours of the widget's own readings, kept in the extension's container.
enum OwnHistory {
    struct Point: Codable {
        var date: Date
        var memory: Double
    }

    private static let key = "memoryHistory"

    static func record(_ data: WidgetData, at date: Date) -> [Point] {
        let defaults = UserDefaults.standard
        var points = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Point].self, from: $0) } ?? [])
            .filter { date.timeIntervalSince($0.date) < 6 * 3600 }
        // Several widgets refresh together: one point per minute is enough.
        if points.last.map({ date.timeIntervalSince($0.date) >= 60 }) ?? true {
            points.append(Point(date: date, memory: data.memory?.fraction ?? 0))
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
        }
    }

    init(_ family: WidgetFamily) {
        self = family == .systemSmall ? .small : .medium
    }
}

struct OverviewWidget: ElementWidget { static let element = WidgetElement.overview }
struct MemoryWidget: ElementWidget { static let element = WidgetElement.memory }
struct DiskWidget: ElementWidget { static let element = WidgetElement.disk }
struct BatteryWidget: ElementWidget { static let element = WidgetElement.battery }
struct WeatherElementWidget: ElementWidget { static let element = WidgetElement.weather }

@main
struct MenuStatsWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        MemoryWidget()
        DiskWidget()
        BatteryWidget()
        WeatherElementWidget()
    }
}
