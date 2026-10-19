import Foundation

/// What the desktop widgets show. The widget extension reads memory, disk and battery itself; MenuStats adds the
/// rest (memory history, Apple's battery health, weather) by writing this as JSON every minute to
/// `~/Library/Application Support/MenuStats/widget.json`, which the sandboxed extension may only read.
public struct WidgetData: Codable, Equatable {
    public struct Memory: Codable, Equatable {
        public var used: UInt64
        public var total: UInt64
        public var app: UInt64
        public var wired: UInt64
        public var compressed: UInt64
        /// 1 normal, 2 warning, 4 critical.
        public var pressure: Int
        public var history: [Double]
        public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        public init(used: UInt64, total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, pressure: Int, history: [Double]) {
            self.used = used; self.total = total; self.app = app; self.wired = wired; self.compressed = compressed
            self.pressure = pressure; self.history = history
        }
    }

    public struct Disk: Codable, Equatable {
        public var name: String
        public var free: UInt64
        public var total: UInt64
        public var usedFraction: Double { total > 0 ? Double(total - min(free, total)) / Double(total) : 0 }
        public init(name: String, free: UInt64, total: UInt64) {
            self.name = name; self.free = free; self.total = total
        }
    }

    public struct Battery: Codable, Equatable {
        public var percent: Double
        public var charging: Bool
        public var pluggedIn: Bool
        public var minutesRemaining: Int?
        public var health: Double?
        public var cycles: Int?
        public var watts: Double?
        public init(percent: Double, charging: Bool, pluggedIn: Bool, minutesRemaining: Int?, health: Double?, cycles: Int?, watts: Double?) {
            self.percent = percent; self.charging = charging; self.pluggedIn = pluggedIn; self.minutesRemaining = minutesRemaining
            self.health = health; self.cycles = cycles; self.watts = watts
        }
    }

    public struct Weather: Codable, Equatable {
        public var city: String
        public var temperature: Double
        public var high: Double?
        public var low: Double?
        public var symbol: String
        public var condition: String
        public var isDay: Bool
        public init(city: String, temperature: Double, high: Double?, low: Double?, symbol: String, condition: String, isDay: Bool) {
            self.city = city; self.temperature = temperature; self.high = high; self.low = low
            self.symbol = symbol; self.condition = condition; self.isDay = isDay
        }
    }

    public var updated: Date
    public var fahrenheit: Bool
    public var chip: String?
    public var memory: Memory?
    public var disk: Disk?
    public var battery: Battery?
    public var weather: Weather?

    public init(updated: Date, fahrenheit: Bool, chip: String?, memory: Memory?, disk: Disk?, battery: Battery?, weather: Weather?) {
        self.updated = updated; self.fahrenheit = fahrenheit; self.chip = chip; self.memory = memory
        self.disk = disk; self.battery = battery; self.weather = weather
    }

    // MARK: - Shared file

    /// Real home directory (inside the widget's sandbox NSHomeDirectory() is its container).
    private static var home: String {
        if let entry = getpwuid(getuid()) { return String(cString: entry.pointee.pw_dir) }
        return NSHomeDirectory()
    }

    public static var fileURL: URL {
        URL(fileURLWithPath: home + "/Library/Application Support/MenuStats/widget.json")
    }

    public static func load(from url: URL = fileURL) -> WidgetData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetData.self, from: data)
    }

    public func save(to url: URL = fileURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Realistic sample for the widget gallery and previews.
    public static let sample = WidgetData(
        updated: Date(), fahrenheit: false, chip: "Apple M3 Pro",
        memory: Memory(used: 12_400_000_000, total: 18_000_000_000, app: 4_600_000_000, wired: 2_900_000_000,
                       compressed: 4_900_000_000, pressure: 1, history: [0.66, 0.67, 0.68, 0.68, 0.69, 0.7, 0.69, 0.69]),
        disk: Disk(name: "Macintosh HD", free: 121_000_000_000, total: 494_000_000_000),
        battery: Battery(percent: 0.78, charging: false, pluggedIn: false, minutesRemaining: 312, health: 0.96, cycles: 205, watts: -9.4),
        weather: Weather(city: "Roma", temperature: 21, high: 24, low: 14, symbol: "cloud.sun.fill", condition: "Parzialmente nuvoloso", isDay: true)
    )
}

/// The elements a widget can show. Only values that change slowly: WidgetKit redraws a widget every few minutes
/// at best, too rarely for CPU, network, temperatures or fans (those stay in the menu bar and the dropdown).
public enum WidgetElement: String, CaseIterable, Codable, Identifiable {
    case overview, memory, disk, battery, weather
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Panoramica"
        case .memory: "Memoria"
        case .disk: "Disco"
        case .battery: "Batteria"
        case .weather: "Meteo"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .weather: "cloud.sun.fill"
        }
    }

    public var summary: String {
        switch self {
        case .overview: "Memoria, disco, batteria e meteo insieme."
        case .memory: "Memoria usata, composizione e pressione."
        case .disk: "Spazio libero e usato del disco di avvio."
        case .battery: "Carica, autonomia e salute."
        case .weather: "Condizioni attuali, massima e minima."
        }
    }

    public var sizes: [WidgetSize] { [.small, .medium] }
}

public enum WidgetSize: String, CaseIterable, Codable, Identifiable {
    case small, medium
    public var id: String { rawValue }
    public var label: String { self == .small ? "Piccolo" : "Medio" }
}
