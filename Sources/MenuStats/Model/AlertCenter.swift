import Foundation
import UserNotifications

/// Threshold notifications (CPU, temperature, battery, fans), with hysteresis so each fires once per episode.
final class AlertCenter {
    private enum Alert: Hashable { case cpu, temperature, batteryLow, batteryCharged, fans }

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

        if settings.alertTemperature, let temperature = snapshot.sensors.cpuAverage {
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

        if settings.alertFans, let fans = snapshot.smc?.fans, let fastest = fans.max(by: { $0.fraction < $1.fraction }) {
            update(.fans, on: fastest.fraction >= 0.7, off: fastest.fraction < 0.5,
                   "Ventole al massimo", "\(fastest.name) a \(Format.rpm(fastest.rpm)).")
        }
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
