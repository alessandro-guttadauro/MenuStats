import AppKit
import Combine

/// The decision part of the proximity lock, free of timers and system calls so it can be tested.
/// A device only counts once it has been seen, so enabling the lock with the phone in another room does nothing.
struct ProximityLogic {
    var lastSeen: [String: Date] = [:]
    /// Set after locking; cleared when a watched device is seen again, so unlocking by hand while the device is
    /// still away does not lock again in a loop.
    var locked = false

    /// Feeds one reading. Returns true when the Mac should lock now.
    mutating func evaluate(present: Set<String>, watched: Set<String>, requiresAll: Bool, grace: TimeInterval,
                           now: Date, canLock: Bool) -> Bool {
        for id in watched where present.contains(id) { lastSeen[id] = now }
        lastSeen = lastSeen.filter { watched.contains($0.key) }
        let tracked = watched.filter { lastSeen[$0] != nil }
        guard !tracked.isEmpty else { return false }

        if tracked.contains(where: { present.contains($0) }) { locked = false }
        guard canLock, !locked else { return false }

        let away = tracked.filter { id in
            guard !present.contains(id), let seen = lastSeen[id] else { return false }
            return now.timeIntervalSince(seen) >= grace
        }
        let lock = requiresAll ? away.count == tracked.count : !away.isEmpty
        if lock { locked = true }
        return lock
    }

    /// After sleep or a screen lock the clocks are stale; give every device a fresh grace period.
    mutating func restartGrace(now: Date) {
        for id in lastSeen.keys { lastSeen[id] = now }
    }
}

/// Locks the Mac when the chosen devices move away. Runs in the background while enabled, whichever tab is open:
/// one `system_profiler` read every few seconds, which macOS answers from its own cache.
final class ProximityLock: ObservableObject {
    /// Chosen devices heard in the last reading, for the Settings page.
    @Published private(set) var presentCount = 0
    @Published private(set) var lastLock: Date?

    private let settings: Settings
    private let reader: () -> [NearbyDeviceReader.Entry]
    private let lockAction: () -> Void
    private let canLockNow: () -> Bool
    private var logic = ProximityLogic()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "menustats.proximity", qos: .utility)

    init(settings: Settings,
         reader: @escaping () -> [NearbyDeviceReader.Entry] = NearbyDeviceReader.sample,
         lockAction: @escaping () -> Void = SystemActions.lockScreen,
         canLockNow: @escaping () -> Bool = SystemActions.screenIsUsable) {
        self.settings = settings
        self.reader = reader
        self.lockAction = lockAction
        self.canLockNow = canLockNow

        // objectWillChange fires before the new value is stored; look at the settings on the next run loop pass.
        settings.objectWillChange.debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.configure() }.store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.logic.restartGrace(now: Date())
            }
        }
        configure()
    }

    /// How often the devices are read: a few times per grace period, between 10 and 60 seconds.
    static func interval(forGrace grace: Int) -> TimeInterval { min(max(Double(grace) / 3, 10), 60) }

    private func configure() {
        let active = settings.proximityLockEnabled && !settings.proximityLockDevices.isEmpty
        guard active else {
            timer?.invalidate()
            timer = nil
            logic = ProximityLogic()
            presentCount = 0
            return
        }
        let interval = Self.interval(forGrace: settings.proximityLockGrace)
        if let timer, abs(timer.timeInterval - interval) < 0.5 { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.read() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        read()
    }

    private func read() {
        queue.async { [weak self] in
            guard let self else { return }
            let entries = reader()
            DispatchQueue.main.async { self.handle(entries, now: Date()) }
        }
    }

    /// Applies one reading. Separate from the timer so tests can drive it.
    func handle(_ entries: [NearbyDeviceReader.Entry], now: Date) {
        guard settings.proximityLockEnabled else { return }
        let watched = Set(settings.proximityLockDevices.keys)
        // A device is here when macOS measures a signal for it or it is connected.
        let present = Set(entries.filter { $0.rssi != nil || $0.connected }.map(\.id)).intersection(watched)
        presentCount = present.count
        let lock = logic.evaluate(present: present, watched: watched, requiresAll: settings.proximityLockRequiresAll,
                                  grace: Double(settings.proximityLockGrace), now: now, canLock: canLockNow())
        if lock {
            lastLock = now
            lockAction()
        }
    }
}
