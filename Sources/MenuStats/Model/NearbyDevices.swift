import Foundation

/// One of the user's own Bluetooth devices, as macOS knows it: paired with this Mac, or an Apple device of the same
/// account (iPhone, iPad, Apple Watch). Other people's devices are never listed.
struct NearbyDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: String?
    var connected: Bool
    /// Signal strength in dBm that macOS reports while the device is in range, smoothed over the last samples.
    var rssi: Double?

    var symbol: String { NearbyMath.symbol(name: name, kind: kind) }
    var distance: Double? { rssi.map { NearbyMath.distance(rssi: $0) } }
    var inRange: Bool { rssi != nil }
}

/// The estimates behind the Nearby card. All approximate: a body, a wall or a pocket changes the signal by 10 dB or more.
enum NearbyMath {
    /// Log-distance path loss with −59 dBm at one meter, a common value for phones and accessories.
    static func distance(rssi: Double, atOneMeter: Double = -59, exponent: Double = 2.2) -> Double {
        pow(10, (atOneMeter - rssi) / (10 * exponent))
    }

    /// Exponential moving average, so one noisy reading does not make a device jump around.
    static func smooth(_ previous: Double?, _ new: Double, weight: Double = 0.5) -> Double {
        previous.map { $0 + weight * (new - $0) } ?? new
    }

    static func label(forDistance meters: Double) -> String {
        switch meters {
        case ..<1: "< 1 m"
        case ..<10: "≈ \(Int(meters.rounded())) m"
        case ..<30: "≈ \(Int((meters / 5).rounded()) * 5) m"
        default: "> 30 m"
        }
    }

    /// An icon from the device type macOS reports, or from its name.
    static func symbol(name: String, kind: String?) -> String {
        let text = name.lowercased()
        let kind = (kind ?? "").lowercased()
        if text.contains("airpods") || kind == "headphones" || kind == "headset" { return "airpodspro" }
        if text.contains("watch") { return "applewatch" }
        if text.contains("iphone") || text.contains("phone") { return "iphone" }
        if text.contains("ipad") { return "ipad" }
        if text.contains("mac") && !text.contains("magic") { return "laptopcomputer" }
        if kind == "keyboard" { return "keyboard" }
        if kind == "mouse" { return "computermouse" }
        if kind == "gamepad" { return "gamecontroller" }
        if kind == "speaker" { return "hifispeaker" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Reads the devices macOS knows, with the signal strength it measures, from `system_profiler SPBluetoothDataType`.
/// No scanning and no Bluetooth permission: it is the same list as System Settings ▸ Bluetooth.
enum NearbyDeviceReader {
    struct Entry: Equatable {
        var id: String
        var name: String
        var kind: String?
        var connected: Bool
        var rssi: Double?
    }

    static func sample() -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data)
    }

    static func parse(_ data: Data) -> [Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var entries: [Entry] = []
        for controller in controllers {
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for item in controller[key] as? [[String: Any]] ?? [] {
                    for (name, info) in item {
                        guard let info = info as? [String: Any], let address = info["device_address"] as? String else { continue }
                        let rssi = (info["device_rssi"] as? NSNumber)?.doubleValue ?? (info["device_rssi"] as? String).flatMap(Double.init)
                        // 0 and positive values mean "no reading".
                        entries.append(Entry(id: address, name: name, kind: info["device_minorType"] as? String, connected: connected,
                                             rssi: rssi.flatMap { $0 < 0 && $0 > -110 ? $0 : nil }))
                    }
                }
            }
        }
        return entries
    }
}

/// Keeps the list fresh while the Map tab is on screen: one `system_profiler` run every few seconds, off the main thread.
final class NearbyDevicesMonitor: ObservableObject {
    @Published private(set) var devices: [NearbyDevice] = []
    @Published private(set) var loaded = false

    static let interval: TimeInterval = 6
    private var timer: Timer?
    private var smoothed: [String: Double] = [:]
    private let queue = DispatchQueue(label: "menustats.nearby", qos: .utility)

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        smoothed.removeAll()
    }

    private func refresh() {
        queue.async { [weak self] in
            let entries = NearbyDeviceReader.sample()
            DispatchQueue.main.async { self?.apply(entries) }
        }
    }

    private func apply(_ entries: [NearbyDeviceReader.Entry]) {
        guard timer != nil else { return } // the tab closed while the reader ran
        var seen = Set<String>()
        let devices: [NearbyDevice] = entries.map { entry in
            seen.insert(entry.id)
            var rssi: Double?
            if let value = entry.rssi {
                rssi = NearbyMath.smooth(smoothed[entry.id], value)
                smoothed[entry.id] = rssi
            } else {
                smoothed[entry.id] = nil
            }
            return NearbyDevice(id: entry.id, name: entry.name, kind: entry.kind, connected: entry.connected, rssi: rssi)
        }
        smoothed = smoothed.filter { seen.contains($0.key) }
        // Nearest first; devices without a reading last, connected ones before the others.
        self.devices = devices.sorted {
            switch ($0.distance, $1.distance) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.connected && !$1.connected
            }
        }
        loaded = true
    }
}
