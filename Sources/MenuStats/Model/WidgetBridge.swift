import Foundation
import MenuStatsWidgetUI
import WidgetKit

extension AppModel {
    /// Widget data from the latest snapshot, with the memory graph of the last hour. `forceWeather` includes the
    /// weather even with the module off (screenshots).
    func widgetData(forceWeather: Bool = false) -> WidgetData {
        let snapshot = snapshot
        func series(_ metric: Metric) -> [Double] {
            history.series(metric, range: .hour).map(\.value).suffix(60)
        }
        let memory = snapshot.memory.map {
            WidgetData.Memory(used: $0.used, total: $0.total, app: $0.app, wired: $0.wired, compressed: $0.compressed,
                              pressure: $0.pressureLevel, history: series(.memory))
        }
        let disk = snapshot.disk.map {
            WidgetData.Disk(name: WidgetBridge.startupVolumeName, free: $0.free, total: $0.total)
        }
        let battery = snapshot.battery.map {
            WidgetData.Battery(percent: $0.percent, charging: $0.isCharging, pluggedIn: $0.onACPower, minutesRemaining: $0.minutesRemaining,
                               health: $0.health, cycles: $0.cycleCount, watts: $0.watts)
        }
        let weather = settings.isEnabled(.weather) || forceWeather ? self.weather.report.map { report in
            WidgetData.Weather(city: report.location.name, temperature: report.temperature, high: report.today?.maximum,
                               low: report.today?.minimum, symbol: report.condition.symbol, condition: report.condition.description,
                               isDay: report.isDay)
        } : nil
        return WidgetData(updated: snapshot.date, fahrenheit: settings.temperatureUnit == .fahrenheit, chip: snapshot.cpu?.brand,
                          memory: memory, disk: disk, battery: battery, weather: weather)
    }
}

/// Adds what the widget extension can't read by itself (memory history, Apple's battery health, weather):
/// writes a small JSON file every minute and asks WidgetKit to redraw now and then. The widgets work without it,
/// reading the live values themselves, so they keep going while MenuStats is closed.
final class WidgetBridge {
    static let exportInterval: TimeInterval = 60
    /// WidgetKit budgets reloads; one every few minutes keeps the widgets current without running out.
    static let reloadInterval: TimeInterval = 5 * 60

    private unowned let model: AppModel
    private var lastExport = Date.distantPast
    private var lastReload = Date.distantPast

    init(model: AppModel) { self.model = model }

    static let startupVolumeName: String = {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }()

    /// Called on every sample; does nothing until a minute has passed.
    func tick(now: Date = Date()) {
        guard now.timeIntervalSince(lastExport) >= Self.exportInterval else { return }
        export(now: now)
    }

    /// Writes right away and redraws the widgets (from Settings ▸ Widget).
    func exportNow() {
        export(now: Date(), forceReload: true)
    }

    private func export(now: Date, forceReload: Bool = false) {
        lastExport = now
        model.widgetData().save()
        // The first export after launch also redraws, so widgets left stale while the app was closed catch up.
        guard forceReload || now.timeIntervalSince(lastReload) >= Self.reloadInterval else { return }
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}
