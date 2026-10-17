import Combine
import Foundation

struct WeatherReport: Equatable {
    struct Hour: Equatable, Identifiable {
        var date: Date
        var temperature: Double
        var code: Int
        var isDay: Bool
        var precipitationChance: Int?
        var id: Date { date }
    }

    struct Day: Equatable, Identifiable {
        var date: Date
        var code: Int
        var minimum: Double
        var maximum: Double
        var precipitationChance: Int?
        var sunrise: Date?
        var sunset: Date?
        var id: Date { date }
    }

    var location: WeatherLocation
    var temperature: Double
    var apparentTemperature: Double?
    var code: Int
    var isDay: Bool
    var humidity: Int?
    var windSpeed: Double?
    var hours: [Hour]
    var days: [Day]
    var updated: Date

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
    var today: Day? { days.first }
}

/// Weather from Open-Meteo (free, no key, no account). Runs only while the Weather module is enabled and a
/// place is chosen: no network otherwise. Only the place's coordinates are sent.
final class WeatherService: ObservableObject {
    @Published private(set) var report: WeatherReport?
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    private var location: WeatherLocation?
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var wakeObserver: NSObjectProtocol?
    private static let refreshInterval: TimeInterval = 15 * 60

    /// Starts, restarts (new place) or stops the service.
    func configure(enabled: Bool, location: WeatherLocation?) {
        guard enabled, let location else {
            stop()
            return
        }
        let changed = location != self.location
        self.location = location
        if changed { report = nil }
        if timer == nil {
            let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 60
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            wakeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("NSWorkspaceDidWakeNotification"),
                                                                  object: nil, queue: .main) { [weak self] _ in self?.refreshIfStale() }
        }
        if changed || report == nil { refresh() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        location = nil
        report = nil
        error = nil
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func refreshIfStale() {
        guard let report else { refresh(); return }
        if Date().timeIntervalSince(report.updated) > Self.refreshInterval - 60 { refresh() }
    }

    func refresh() {
        guard let location else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", location.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", location.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,relative_humidity_2m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
        ]
        task?.cancel()
        loading = true
        task = URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, error in
            let parsed = data.flatMap { Self.parse($0, location: location) }
            DispatchQueue.main.async {
                guard let self, self.location == location else { return }
                self.loading = false
                if let parsed {
                    self.report = parsed
                    self.error = nil
                } else if (error as? URLError)?.code != .cancelled {
                    self.error = "Meteo non disponibile: controlla la connessione."
                }
            }
        }
        task?.resume()
    }

    // MARK: - Parsing

    private static func parse(_ data: Data, location: WeatherLocation) -> WeatherReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int else { return nil }
        let zone = (root["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let day = DateFormatter()
        day.locale = local.locale
        day.timeZone = zone
        day.dateFormat = "yyyy-MM-dd"

        var hours: [WeatherReport.Hour] = []
        if let hourly = root["hourly"] as? [String: Any], let times = hourly["time"] as? [String] {
            let temps = hourly["temperature_2m"] as? [Double] ?? []
            let codes = hourly["weather_code"] as? [Int] ?? []
            let rain = hourly["precipitation_probability"] as? [Int?] ?? []
            let isDay = hourly["is_day"] as? [Int] ?? []
            let now = Date().addingTimeInterval(-3600)
            for (index, time) in times.enumerated() {
                guard let date = local.date(from: time), date >= now, index < temps.count, index < codes.count else { continue }
                hours.append(.init(date: date, temperature: temps[index], code: codes[index],
                                   isDay: index < isDay.count ? isDay[index] == 1 : true,
                                   precipitationChance: index < rain.count ? rain[index] : nil))
                if hours.count == 24 { break }
            }
        }

        var days: [WeatherReport.Day] = []
        if let daily = root["daily"] as? [String: Any], let times = daily["time"] as? [String] {
            let codes = daily["weather_code"] as? [Int] ?? []
            let maxima = daily["temperature_2m_max"] as? [Double] ?? []
            let minima = daily["temperature_2m_min"] as? [Double] ?? []
            let rain = daily["precipitation_probability_max"] as? [Int?] ?? []
            let sunrise = daily["sunrise"] as? [String] ?? []
            let sunset = daily["sunset"] as? [String] ?? []
            for (index, time) in times.enumerated() {
                guard let date = day.date(from: time), index < codes.count, index < maxima.count, index < minima.count else { continue }
                days.append(.init(date: date, code: codes[index], minimum: minima[index], maximum: maxima[index],
                                  precipitationChance: index < rain.count ? rain[index] : nil,
                                  sunrise: index < sunrise.count ? local.date(from: sunrise[index]) : nil,
                                  sunset: index < sunset.count ? local.date(from: sunset[index]) : nil))
            }
        }

        return WeatherReport(
            location: location,
            temperature: temperature,
            apparentTemperature: current["apparent_temperature"] as? Double,
            code: code,
            isDay: (current["is_day"] as? Int ?? 1) == 1,
            humidity: current["relative_humidity_2m"] as? Int,
            windSpeed: current["wind_speed_10m"] as? Double,
            hours: hours,
            days: days,
            updated: Date()
        )
    }

    // MARK: - Place search

    /// Finds places by name (Open-Meteo geocoding). Only the typed text is sent.
    static func search(_ query: String, completion: @escaping ([WeatherLocation]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { completion([]); return }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: trimmed), .init(name: "count", value: "8"),
            .init(name: "language", value: "it"), .init(name: "format", value: "json"),
        ]
        URLSession.shared.dataTask(with: components.url!) { data, _, _ in
            let results = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["results"] as? [[String: Any]]) ?? []
            let places = results.compactMap { item -> WeatherLocation? in
                guard let name = item["name"] as? String, let latitude = item["latitude"] as? Double,
                      let longitude = item["longitude"] as? Double else { return nil }
                return WeatherLocation(name: name, region: item["admin1"] as? String, country: item["country"] as? String,
                                       latitude: latitude, longitude: longitude)
            }
            DispatchQueue.main.async { completion(places) }
        }.resume()
    }
}

/// WMO weather codes (as used by Open-Meteo) → SF Symbol and Italian description.
struct WeatherCondition {
    var code: Int
    var isDay: Bool

    var symbol: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "sun.min.fill" : "moon.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95: "cloud.bolt.rain.fill"
        case 96, 99: "cloud.bolt.fill"
        default: "cloud.fill"
        }
    }

    /// Outline variant for the monochrome menu bar.
    var menubarSymbol: String { symbol.replacingOccurrences(of: ".fill", with: "") }

    var description: String {
        switch code {
        case 0: "Sereno"
        case 1: "Prevalentemente sereno"
        case 2: "Parzialmente nuvoloso"
        case 3: "Coperto"
        case 45, 48: "Nebbia"
        case 51, 53, 55: "Pioviggine"
        case 56, 57: "Pioviggine gelata"
        case 61: "Pioggia debole"
        case 63: "Pioggia"
        case 65: "Pioggia forte"
        case 66, 67: "Pioggia gelata"
        case 71: "Neve debole"
        case 73: "Neve"
        case 75: "Neve forte"
        case 77: "Nevischio"
        case 80, 81: "Rovesci"
        case 82: "Rovesci forti"
        case 85, 86: "Rovesci di neve"
        case 95: "Temporale"
        case 96, 99: "Temporale con grandine"
        default: "—"
        }
    }
}
