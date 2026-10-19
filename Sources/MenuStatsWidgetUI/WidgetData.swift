import Foundation

/// Snapshot shared by the app and its desktop widgets: the app writes it as JSON every minute to
/// `~/Library/Application Support/MenuStats/widget.json`; the sandboxed widget extension only reads it.
/// The dropdown's Widget tab builds the same structure from live data on every sample.
public struct WidgetData: Codable, Equatable {
    public struct CPU: Codable, Equatable {
        public var total: Double
        public var user: Double
        public var system: Double
        public var efficiencyAverage: Double?
        public var performanceAverage: Double?
        public var history: [Double]
        public init(total: Double, user: Double, system: Double, efficiencyAverage: Double?, performanceAverage: Double?, history: [Double]) {
            self.total = total; self.user = user; self.system = system
            self.efficiencyAverage = efficiencyAverage; self.performanceAverage = performanceAverage; self.history = history
        }
    }

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
        public var readRate: Double
        public var writeRate: Double
        public var usedFraction: Double { total > 0 ? Double(total - min(free, total)) / Double(total) : 0 }
        public init(name: String, free: UInt64, total: UInt64, readRate: Double, writeRate: Double) {
            self.name = name; self.free = free; self.total = total; self.readRate = readRate; self.writeRate = writeRate
        }
    }

    public struct Network: Codable, Equatable {
        public var download: Double
        public var upload: Double
        public var interface: String?
        public var address: String?
        public var downloadHistory: [Double]
        public var uploadHistory: [Double]
        public init(download: Double, upload: Double, interface: String?, address: String?, downloadHistory: [Double], uploadHistory: [Double]) {
            self.download = download; self.upload = upload; self.interface = interface; self.address = address
            self.downloadHistory = downloadHistory; self.uploadHistory = uploadHistory
        }
    }

    public struct Temperature: Codable, Equatable {
        public var cpu: Double?
        public var cpuMax: Double?
        public var gpu: Double?
        public var ssd: Double?
        /// 0 nominal … 3 critical (ProcessInfo.ThermalState).
        public var thermalState: Int
        public var history: [Double]
        public init(cpu: Double?, cpuMax: Double?, gpu: Double?, ssd: Double?, thermalState: Int, history: [Double]) {
            self.cpu = cpu; self.cpuMax = cpuMax; self.gpu = gpu; self.ssd = ssd; self.thermalState = thermalState; self.history = history
        }
    }

    public struct Fan: Codable, Equatable, Identifiable {
        public var id: Int
        public var rpm: Double
        public var fraction: Double
        public init(id: Int, rpm: Double, fraction: Double) { self.id = id; self.rpm = rpm; self.fraction = fraction }
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
    public var cpu: CPU?
    public var memory: Memory?
    public var disk: Disk?
    public var network: Network?
    public var temperature: Temperature?
    public var fans: [Fan]
    public var battery: Battery?
    public var weather: Weather?

    public init(updated: Date, fahrenheit: Bool, chip: String?, cpu: CPU?, memory: Memory?, disk: Disk?, network: Network?,
                temperature: Temperature?, fans: [Fan], battery: Battery?, weather: Weather?) {
        self.updated = updated; self.fahrenheit = fahrenheit; self.chip = chip; self.cpu = cpu; self.memory = memory
        self.disk = disk; self.network = network; self.temperature = temperature; self.fans = fans; self.battery = battery
        self.weather = weather
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
        cpu: CPU(total: 0.24, user: 0.15, system: 0.09, efficiencyAverage: 0.31, performanceAverage: 0.18,
                 history: [0.12, 0.18, 0.22, 0.35, 0.28, 0.2, 0.31, 0.42, 0.26, 0.19, 0.24, 0.3, 0.22, 0.24]),
        memory: Memory(used: 12_400_000_000, total: 18_000_000_000, app: 4_600_000_000, wired: 2_900_000_000,
                       compressed: 4_900_000_000, pressure: 1, history: [0.66, 0.67, 0.68, 0.68, 0.69, 0.7, 0.69, 0.69]),
        disk: Disk(name: "Macintosh HD", free: 121_000_000_000, total: 494_000_000_000, readRate: 1_800_000, writeRate: 420_000),
        network: Network(download: 2_400_000, upload: 310_000, interface: "en0", address: "192.168.1.45",
                         downloadHistory: [0.2, 0.5, 1.4, 0.8, 2.6, 1.9, 0.7, 2.4].map { $0 * 1_000_000 },
                         uploadHistory: [0.05, 0.1, 0.3, 0.2, 0.4, 0.2, 0.1, 0.31].map { $0 * 1_000_000 }),
        temperature: Temperature(cpu: 47, cpuMax: 53, gpu: 42, ssd: 31, thermalState: 0, history: [44, 45, 46, 48, 47, 46, 47]),
        fans: [Fan(id: 0, rpm: 2400, fraction: 0.35), Fan(id: 1, rpm: 2380, fraction: 0.35)],
        battery: Battery(percent: 0.78, charging: false, pluggedIn: false, minutesRemaining: 312, health: 0.96, cycles: 205, watts: -9.4),
        weather: Weather(city: "Roma", temperature: 21, high: 24, low: 14, symbol: "cloud.sun.fill", condition: "Parzialmente nuvoloso", isDay: true)
    )
}

/// The elements a widget can show.
public enum WidgetElement: String, CaseIterable, Codable, Identifiable {
    case overview, cpu, memory, disk, network, temperature, fans, battery, weather
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Panoramica"
        case .cpu: "CPU"
        case .memory: "Memoria"
        case .disk: "Disco"
        case .network: "Rete"
        case .temperature: "Temperature"
        case .fans: "Ventole"
        case .battery: "Batteria"
        case .weather: "Meteo"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .temperature: "thermometer.medium"
        case .fans: "fan"
        case .battery: "battery.75percent"
        case .weather: "cloud.sun.fill"
        }
    }

    public var summary: String {
        switch self {
        case .overview: "Tutti gli elementi insieme."
        case .cpu: "Utilizzo, utente e sistema, andamento recente."
        case .memory: "Memoria usata, composizione e pressione."
        case .disk: "Spazio libero e attività del disco."
        case .network: "Download, upload e andamento recente."
        case .temperature: "CPU, GPU e SSD, stato termico."
        case .fans: "Velocità delle ventole."
        case .battery: "Carica, autonomia e salute."
        case .weather: "Condizioni attuali, massima e minima."
        }
    }

    /// Sizes offered for this element.
    public var sizes: [WidgetSize] { self == .overview ? [.small, .medium, .large] : [.small, .medium] }
}

public enum WidgetSize: String, CaseIterable, Codable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    public var label: String { ["Piccolo", "Medio", "Grande"][Self.allCases.firstIndex(of: self)!] }
}
