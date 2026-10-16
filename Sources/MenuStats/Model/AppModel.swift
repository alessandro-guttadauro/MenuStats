import Combine
import Foundation

/// A slower copy of the latest snapshot (every 5 s), for views that don't need every sample (the settings previews).
final class SlowFeed: ObservableObject {
    @Published fileprivate(set) var snapshot = Snapshot()
    unowned let model: AppModel
    init(model: AppModel) { self.model = model }
}

struct LivePoint {
    var date: Date
    var value: Double
}

/// Shared app state: samples the system on a timer, keeps live buffers and the SQLite history,
/// and publishes each new Snapshot to the menu bar and the dashboard.
final class AppModel: ObservableObject {
    static let liveLength = 150 // 5 minutes at the default 2 s interval

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var networkProcesses: [ProcessNetworkUsage] = []

    let settings: Settings
    let history: HistoryStore
    let hardware = HardwareControl()
    private(set) lazy var slowFeed = SlowFeed(model: self)
    private var lastSlowUpdate = Date.distantPast
    private let monitor = SystemMonitor()
    private let networkProcessReader = NetworkProcessReader()
    private let alerts = AlertCenter()
    private var live: [Metric: [LivePoint]] = [:]
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: Settings = .shared, history: HistoryStore = HistoryStore()) {
        self.settings = settings
        self.history = history
        networkProcessReader.onUpdate = { [weak self] usage in self?.networkProcesses = usage }
        settings.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in self?.schedule(interval) }
            .store(in: &cancellables)
    }

    func start() {
        tick()
        schedule(settings.refreshInterval)
    }

    private func schedule(_ interval: Double) {
        timer?.invalidate()
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common) // keeps ticking while menus or the panel are tracking
        self.timer = timer
    }

    func tick() {
        let snapshot = monitor.sample()
        let values = snapshot.historyValues
        history.record(values)
        for (metric, value) in values where value.isFinite {
            var buffer = live[metric] ?? []
            buffer.append(LivePoint(date: snapshot.date, value: value))
            if buffer.count > Self.liveLength { buffer.removeFirst(buffer.count - Self.liveLength) }
            live[metric] = buffer
        }
        alerts.evaluate(snapshot, settings: settings)
        self.snapshot = snapshot
        if snapshot.date.timeIntervalSince(lastSlowUpdate) >= 5 {
            lastSlowUpdate = snapshot.date
            slowFeed.snapshot = snapshot
        }
    }

    func livePoints(_ metric: Metric) -> [LivePoint] { live[metric] ?? [] }

    func warmUpSensors() { monitor.sampleSensorsNow() }

    /// Temperatures refresh every sample while the sensors tab is visible, every 5 s otherwise.
    func setFastSensors(_ enabled: Bool) {
        monitor.sensorsInterval = enabled ? 0 : 5
    }

    /// Recent values for the small graphs drawn in the menu bar.
    func recentValues(_ metric: Metric, count: Int) -> [Double] {
        (live[metric] ?? []).suffix(count).map(\.value)
    }

    // Per-process network sampling is only needed while the network tab is on screen.
    func setNetworkProcessSampling(_ enabled: Bool) {
        if enabled { networkProcessReader.start() } else { networkProcessReader.stop(); networkProcesses = [] }
    }
}
