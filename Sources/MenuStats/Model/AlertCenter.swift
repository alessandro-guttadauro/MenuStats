import Foundation
import UserNotifications

/// Threshold notifications (CPU, temperature, battery, fans, a busy app, a full disk, a lost network),
/// with hysteresis so each fires once per episode.
final class AlertCenter {
    private enum Alert: Hashable { case cpu, temperature, batteryLow, batteryCharged, fans, appCPU(String), diskLow, networkDown }

    /// Own process sampler for the busy-app alert: runs every 30 s, and only while that alert is on.
    private let processReader = ProcessReader()
    private var lastProcessSample: Date?
    /// Apps above the threshold and since when.
    private var busyApps: [String: Date] = [:]
    private var lastDiskCheck: Date?
    private var offlineSince: Date?
    private static let appBusyDuration: TimeInterval = 2 * 60

    private var active: Set<Alert> = []
    private var cpuHighSince: Date?
    private var lastFired: [Alert: Date] = [:]
    private var authorizationRequested = false
    private static let cooldown: TimeInterval = 10 * 60

    func evaluate(_ snapshot: Snapshot, settings: Settings) {
        // CPU: sustained for 30 s, so short spikes don't notify.
        if settings.alertCPU, let cpu = snapshot.cpu?.total {
            if cpu >= settings.alertCPUThreshold {
                cpuHighSince = cpuHighSince ?? snapshot.date
                if snapshot.date.timeIntervalSince(cpuHighSince!) >= 30 {
                    fire(.cpu, "CPU sotto carico", "Utilizzo CPU al \(Format.percent(cpu)) da più di 30 secondi.")
                }
            } else if cpu < settings.alertCPUThreshold - 0.1 {
                cpuHighSince = nil
                active.remove(.cpu)
            }
        }

        if settings.alertTemperature, let temperature = snapshot.cpuTemperature {
            update(.temperature, on: temperature >= settings.alertTemperatureThreshold,
                   off: temperature < settings.alertTemperatureThreshold - 5,
                   "Temperatura elevata", "La CPU è a \(Format.temperature(temperature)).")
        }

        if let battery = snapshot.battery {
            if settings.alertBatteryLow {
                update(.batteryLow, on: !battery.onACPower && battery.percent <= settings.alertBatteryLowThreshold,
                       off: battery.onACPower || battery.percent > settings.alertBatteryLowThreshold + 0.05,
                       "Batteria scarica", "Carica al \(Format.percent(battery.percent)). Collega l'alimentatore.")
            }
            if settings.alertBatteryCharged {
                update(.batteryCharged, on: battery.onACPower && battery.percent >= settings.alertBatteryChargedThreshold,
                       off: battery.percent < settings.alertBatteryChargedThreshold - 0.05,
                       "Batteria carica", "Carica al \(Format.percent(battery.percent)): puoi scollegare l'alimentatore.")
            }
        }

        if settings.alertAppCPU { evaluateApps(at: snapshot.date, threshold: settings.alertAppCPUThreshold) }

        if settings.alertDiskLow, lastDiskCheck.map({ snapshot.date.timeIntervalSince($0) >= 5 * 60 }) ?? true {
            lastDiskCheck = snapshot.date
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity, total > 0 {
                let fraction = Double(free) / Double(total)
                update(.diskLow, on: fraction <= settings.alertDiskLowThreshold, off: fraction > settings.alertDiskLowThreshold + 0.02,
                       "Disco quasi pieno", "Restano \(Format.storage(UInt64(free))) liberi (\(Format.percent(fraction))).")
            }
        }

        if settings.alertNetworkDown, let network = snapshot.network {
            if network.interface == nil {
                offlineSince = offlineSince ?? snapshot.date
                // 20 s without a primary interface, so a Wi-Fi roam doesn't notify.
                if snapshot.date.timeIntervalSince(offlineSince!) >= 20 {
                    fire(.networkDown, "Rete assente", "Il Mac non è connesso a nessuna rete da più di 20 secondi.")
                }
            } else {
                offlineSince = nil
                active.remove(.networkDown)
            }
        }

        if settings.alertFans, let fans = snapshot.smc?.fans, let fastest = fans.max(by: { $0.fraction < $1.fraction }) {
            update(.fans, on: fastest.fraction >= 0.7, off: fastest.fraction < 0.5,
                   "Ventole al massimo", "\(fastest.name) a \(Format.rpm(fastest.rpm)).")
        }
    }

    /// An app (helpers grouped with their app) using more than `threshold` of a core for two minutes.
    private func evaluateApps(at date: Date, threshold: Double) {
        guard lastProcessSample.map({ date.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastProcessSample = date
        let groups = ProcessGrouping.groups(processReader.sample(), byApp: true)
        var stillBusy: [String: Date] = [:]
        for group in groups where group.cpu >= threshold {
            let since = busyApps[group.name] ?? date
            stillBusy[group.name] = since
            if date.timeIntervalSince(since) >= Self.appBusyDuration {
                fire(.appCPU(group.name), "\(group.name) usa molta CPU",
                     "\(group.name) è al \(Format.percent(group.cpu)) di CPU da più di 2 minuti.")
            }
        }
        for name in busyApps.keys where stillBusy[name] == nil { active.remove(.appCPU(name)) }
        busyApps = stillBusy
    }

    private func update(_ alert: Alert, on: Bool, off: Bool, _ title: String, _ body: String) {
        if on { fire(alert, title, body) } else if off { active.remove(alert) }
    }

    private func fire(_ alert: Alert, _ title: String, _ body: String) {
        guard !active.contains(alert) else { return }
        active.insert(alert)
        if let last = lastFired[alert], Date().timeIntervalSince(last) < Self.cooldown { return }
        lastFired[alert] = Date()

        // Notifications need an app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
