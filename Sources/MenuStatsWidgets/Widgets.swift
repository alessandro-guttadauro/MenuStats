import MenuStatsWidgetUI
import SwiftUI
import WidgetKit

// Desktop and Notification Center widgets. The extension is sandboxed: it only reads the snapshot that
// MenuStats writes every minute (read-only exception for ~/Library/Application Support/MenuStats/).

struct StatsEntry: TimelineEntry {
    var date: Date
    var data: WidgetData?
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry { StatsEntry(date: Date(), data: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(StatsEntry(date: Date(), data: context.isPreview ? (WidgetData.load() ?? .sample) : WidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        // MenuStats asks for a reload whenever it writes new data; this is the fallback when it doesn't.
        let entry = StatsEntry(date: Date(), data: WidgetData.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
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
    }
}

struct SizedWidgetView: View {
    var element: WidgetElement
    var data: WidgetData?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        MenuStatsWidgetView(element: element, size: WidgetSize(family), data: data)
            .widgetBackground(element)
    }
}

extension View {
    /// macOS 14+ draws the background as the widget's container; macOS 13 needs it behind the content.
    @ViewBuilder
    func widgetBackground(_ element: WidgetElement) -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(for: .widget) { WidgetBackground(element: element) }
        } else {
            padding().background(WidgetBackground(element: element))
        }
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
struct NetworkWidget: ElementWidget { static let element = WidgetElement.network }
struct TemperatureWidget: ElementWidget { static let element = WidgetElement.temperature }
struct FansWidget: ElementWidget { static let element = WidgetElement.fans }
struct BatteryWidget: ElementWidget { static let element = WidgetElement.battery }
struct WeatherWidget: ElementWidget { static let element = WidgetElement.weather }

@main
struct MenuStatsWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        CPUWidget()
        MemoryWidget()
        DiskWidget()
        NetworkWidget()
        TemperatureWidget()
        FansWidget()
        BatteryWidget()
        WeatherWidget()
    }
}
