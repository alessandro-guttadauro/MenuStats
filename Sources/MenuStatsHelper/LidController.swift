import CIOKitPrivate
import Foundation
import IOKit
import IOKit.ps
import MenuStatsShared

/// Keeps the Mac awake with the lid closed through the "SleepDisabled" power setting (what `pmset disablesleep 1` sets).
/// That blocks every kind of sleep, so it is only ever held on behalf of a connected app, and handed back to macOS when:
/// the app asks, the app quits or crashes, the app stops renewing its lease (hung), the helper is stopped, macOS reports
/// serious thermal pressure, or the battery is nearly empty. A marker file written before the switch survives a helper
/// crash or a power cut, so the next helper start (RunAtLoad, also at boot) switches it back off.
/// A SleepDisabled already set by someone else (the user with pmset) is never touched.
final class LidController {
    /// The system switch, behind a protocol so the rules can be tested without touching the real Mac.
    struct Power {
        var isSleepDisabled: () -> Bool?
        var setSleepDisabled: (Bool) -> Bool

        static let system = Power(isSleepDisabled: { LidController.sleepDisabled }, setSleepDisabled: LidController.setSleepDisabled)
    }

    private let queue = DispatchQueue(label: "local.menustats.helper.lid")
    private let marker: URL
    private let power: Power
    private let failsafe: () -> String?
    private let now: () -> Date

    init(marker: URL = URL(fileURLWithPath: "/Library/Application Support/MenuStats/lid-awake"), power: Power = .system,
         failsafe: @escaping () -> String? = LidController.failsafeReason, now: @escaping () -> Date = Date.init) {
        self.marker = marker
        self.power = power
        self.failsafe = failsafe
        self.now = now
    }
    /// Client → last renewal.
    private var holders: [ObjectIdentifier: Date] = [:]
    /// Why the last holders were dropped, for the app.
    private(set) var releaseReason: String?
    private var watchdog: DispatchSourceTimer?

    /// At helper start: undo a switch left on by a previous helper that died while holding it.
    func recover() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: marker.path) else { return }
            NSLog("MenuStatsHelper: sleep enabled again (left on by a previous run)")
            switchOffLocked()
        }
    }

    func acquire(owner: ObjectIdentifier) -> String? {
        queue.sync {
            if let refusal = failsafe() { return refusal }
            if holders.isEmpty, !FileManager.default.fileExists(atPath: marker.path) {
                if power.isSleepDisabled() != true {
                    // Marker first: if anything dies right after the switch, the next start still switches it back.
                    do {
                        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data().write(to: marker)
                    } catch {
                        return "Impossibile preparare il ripristino: \(error.localizedDescription)"
                    }
                    guard power.setSleepDisabled(true), power.isSleepDisabled() == true else {
                        try? FileManager.default.removeItem(at: marker)
                        return "macOS ha rifiutato di disattivare lo stop"
                    }
                    NSLog("MenuStatsHelper: Mac stays awake with the lid closed")
                }
                // else: SleepDisabled set by someone else; the lid already keeps the Mac awake and it is not ours to undo.
            }
            holders[owner] = now()
            releaseReason = nil
            startWatchdogLocked()
            return nil
        }
    }

    func renew(owner: ObjectIdentifier) -> (Bool, String?) {
        queue.sync {
            guard holders[owner] != nil else { return (false, releaseReason) }
            holders[owner] = now()
            return (true, nil)
        }
    }

    func release(owner: ObjectIdentifier, reason: String) {
        queue.sync {
            guard holders.removeValue(forKey: owner) != nil, holders.isEmpty else { return }
            NSLog("MenuStatsHelper: sleep enabled again (\(reason))")
            switchOffLocked()
        }
    }

    /// Drops every holder. Safe to call at any time, from any thread.
    func restore(reason: String) {
        queue.sync { restoreLocked(reason: reason) }
    }

    private func restoreLocked(reason: String) {
        if !holders.isEmpty || FileManager.default.fileExists(atPath: marker.path) {
            NSLog("MenuStatsHelper: sleep enabled again (\(reason))")
            releaseReason = reason
        }
        holders.removeAll()
        switchOffLocked()
    }

    private func switchOffLocked() {
        if FileManager.default.fileExists(atPath: marker.path) {
            if !power.setSleepDisabled(false) { NSLog("MenuStatsHelper: could not enable sleep again") }
            try? FileManager.default.removeItem(at: marker)
        }
        watchdog?.cancel()
        watchdog = nil
    }

    /// Every 20 s while held: expired leases, thermal pressure and battery.
    private func startWatchdogLocked() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.checkLocked() }
        timer.resume()
        watchdog = timer
    }

    /// The watchdog's check, also callable directly (tests).
    func check() { queue.sync { checkLocked() } }

    /// Clients currently holding the lid awake.
    var holderCount: Int { queue.sync { holders.count } }

    private func checkLocked() {
        if let reason = failsafe() { restoreLocked(reason: reason); return }
        let now = now()
        let expired = holders.filter { now.timeIntervalSince($0.value) > HelperConstants.lidLeaseSeconds }
        if !expired.isEmpty, expired.count == holders.count {
            restoreLocked(reason: "MenuStats non risponde")
        } else {
            for owner in expired.keys { holders[owner] = nil }
        }
    }

    /// Conditions under which the lid must be able to put the Mac to sleep, whatever the app asks.
    static func failsafeReason() -> String? {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "Il Mac è troppo caldo"
        }
        if let charge = batteryCharge(), charge <= HelperConstants.lidMinimumBattery {
            return "Batteria quasi scarica"
        }
        return nil
    }

    /// Charge 0…1 of the internal battery while running on it; nil on AC power or without a battery.
    private static func batteryCharge() -> Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as NSDictionary? as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            return current / maximum
        }
        return nil
    }

    /// macOS's "SleepDisabled" power setting, the one `pmset disablesleep` changes and `pmset -g` shows.
    static var sleepDisabled: Bool? {
        guard let settings = MSPMCopySystemPowerSettings() as? [String: Any] else { return nil }
        return (settings["SleepDisabled"] as? NSNumber)?.boolValue ?? false
    }

    /// Needs root. Writing IOPMrootDomain's property directly is refused by current macOS: this goes through powerd,
    /// like `pmset`. The new value can take a moment to show, so it is read back for up to a second.
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard MSPMSetSystemPowerSetting("SleepDisabled" as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse) == kIOReturnSuccess
        else { return false }
        for _ in 0..<20 {
            if sleepDisabled == disabled { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return sleepDisabled == disabled
    }
}
