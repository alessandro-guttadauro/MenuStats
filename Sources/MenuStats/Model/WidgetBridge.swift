import Foundation
import MenuStatsWidgetUI
import WidgetKit

extension AppModel {
    /// Widget data from the latest snapshot. `minutes` takes the graphs from the per-minute history (last hour,
    /// for the desktop widgets); otherwise from the live buffer (last two minutes, for the dropdown).
    func widgetData(minutes: Bool, forceWeather: Bool = false) -> WidgetData {
        let snapshot = snapshot
        func series(_ metric: Metric) -> [Double] {
            minutes ? history.series(metric, range: .hour).map(\.value).suffix(60) : recentValues(metric, count: 60)
        }
        let cpu = snapshot.cpu.map { cpu -> WidgetData.CPU in
            let efficiency = min(cpu.efficiencyCores, cpu.perCore.count)
            func average(_ cores: ArraySlice<Double>) -> Double? { cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count) }
            return WidgetData.CPU(total: cpu.total, user: cpu.user, system: cpu.system,
                                  efficiencyAverage: efficiency > 0 ? average(cpu.perCore.prefix(efficiency)) : nil,
                                  performanceAverage: efficiency > 0 ? average(cpu.perCore.dropFirst(efficiency)) : nil,
                                  history: series(.cpu))
        }
        let memory = snapshot.memory.map {
            WidgetData.Memory(used: $0.used, total: $0.total, app: $0.app, wired: $0.wired, compressed: $0.compressed,
                              pressure: $0.pressureLevel, history: series(.memory))
        }
        let disk = snapshot.disk.map {
            WidgetData.Disk(name: WidgetBridge.startupVolumeName, free: $0.free, total: $0.total, readRate: $0.readRate, writeRate: $0.writeRate)
        }
        let network = snapshot.network.map {
            WidgetData.Network(download: $0.downloadRate, upload: $0.uploadRate, interface: $0.interface, address: $0.ipAddress,
                               downloadHistory: series(.netDown), uploadHistory: series(.netUp))
        }
        let temperature = snapshot.cpuTemperature.map {
            WidgetData.Temperature(cpu: $0, cpuMax: snapshot.cpuTemperatureMax, gpu: snapshot.gpuTemperature, ssd: snapshot.ssdTemperature,
                                   thermalState: snapshot.thermalState.rawValue, history: series(.cpuTemp))
        }
        let fans = (snapshot.smc?.fans ?? []).map { WidgetData.Fan(id: $0.id, rpm: $0.rpm, fraction: $0.fraction) }
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
                          cpu: cpu, memory: memory, disk: disk, network: network, temperature: temperature, fans: fans,
                          battery: battery, weather: weather)
    }
}

/// Adds what the widget extension can't read by itself (per-minute history, Apple's battery health, weather):
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
        model.widgetData(minutes: true).save()
        // The first export after launch also redraws, so widgets left stale while the app was closed catch up.
        guard forceReload || now.timeIntervalSince(lastReload) >= Self.reloadInterval else { return }
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}
