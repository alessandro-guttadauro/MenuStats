import Foundation
import IOKit

/// Battery of a connected Bluetooth accessory. AirPods report each bud and the case separately.
struct DeviceBattery: Identifiable, Equatable {
    struct Level: Equatable {
        var label: String?
        var percent: Double
    }

    var name: String
    var symbol: String
    var levels: [Level]
    var id: String { name }
}

/// Mice, keyboards and trackpads expose `BatteryPercent` in the IORegistry; AirPods and Beats only appear in
/// `system_profiler SPBluetoothDataType`, which takes about a second, so this runs off the main thread and rarely.
/// iPhone and iPad batteries aren't shared with the Mac over Bluetooth.
enum DeviceBatteryReader {
    static func sample() -> [DeviceBattery] {
        var devices = hidDevices()
        for device in profilerDevices() where !devices.contains(where: { $0.name == device.name }) {
            devices.append(device)
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hidDevices() -> [DeviceBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [DeviceBattery] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard let percent = (property("BatteryPercent") as? NSNumber)?.doubleValue,
                  let name = property("Product") as? String, !devices.contains(where: { $0.name == name }) else { continue }
            devices.append(DeviceBattery(name: name, symbol: symbol(for: name), levels: [.init(label: nil, percent: percent / 100)]))
        }
        return devices
    }

    private static func profilerDevices() -> [DeviceBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [DeviceBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let parts: [(String, String?)] = [
                        ("device_batteryLevelMain", nil), ("device_batteryLevel", nil),
                        ("device_batteryLevelLeft", "Sinistro"), ("device_batteryLevelRight", "Destro"),
                        ("device_batteryLevelCase", "Custodia"),
                    ]
                    let levels = parts.compactMap { key, label -> DeviceBattery.Level? in
                        guard let text = info[key] as? String, let number = Double(text.filter(\.isNumber)) else { return nil }
                        return .init(label: label, percent: number / 100)
                    }
                    if !levels.isEmpty {
                        devices.append(DeviceBattery(name: name, symbol: symbol(for: name, minorType: info["device_minorType"] as? String), levels: levels))
                    }
                }
            }
        }
        return devices
    }

    private static func symbol(for name: String, minorType: String? = nil) -> String {
        let text = (name + " " + (minorType ?? "")).lowercased()
        if text.contains("airpods max") { return "airpodsmax" }
        if text.contains("airpods pro") { return "airpodspro" }
        if text.contains("airpods") { return "airpods" }
        if text.contains("beats") || text.contains("headphone") || text.contains("cuffie") { return "headphones" }
        if text.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if text.contains("mouse") { return "magicmouse" }
        if text.contains("keyboard") || text.contains("tastiera") { return "keyboard" }
        if text.contains("controller") || text.contains("gamepad") { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Keeps the list fresh while the Battery tab is open (once a minute).
final class DeviceBatteryMonitor: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var loaded = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "MenuStats.deviceBatteries", qos: .utility)

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        queue.async { [weak self] in
            let devices = DeviceBatteryReader.sample()
            DispatchQueue.main.async {
                self?.devices = devices
                self?.loaded = true
            }
        }
    }
}
