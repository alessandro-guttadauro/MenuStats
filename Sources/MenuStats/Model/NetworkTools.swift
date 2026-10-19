import Foundation

/// On-demand ping and speed test for the Network tab. Both use macOS' own tools (`ping`, `networkQuality`)
/// and run only when the user presses the button.
final class NetworkTools: ObservableObject {
    struct PingResult: Equatable {
        var host: String
        var average: Double?
        var minimum: Double?
        var maximum: Double?
        var loss: Double?
    }

    struct SpeedResult: Equatable {
        /// Bits per second.
        var download: Double?
        var upload: Double?
        /// Round trips per minute under load (Apple's "responsiveness").
        var responsiveness: Double?
        var date: Date
    }

    static let shared = NetworkTools()

    @Published private(set) var ping: PingResult?
    @Published private(set) var pinging = false
    @Published private(set) var speed: SpeedResult?
    @Published private(set) var testingSpeed = false
    @Published private(set) var error: String?

    private let queue = DispatchQueue(label: "MenuStats.networkTools", qos: .userInitiated)

    func runPing(host rawHost: String) {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        // A hostname or address only: no spaces or options reach `ping`.
        guard !pinging, !host.isEmpty, !host.hasPrefix("-"), host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else {
            error = "Indirizzo non valido"
            return
        }
        pinging = true
        error = nil
        queue.async { [weak self] in
            let output = Self.run("/sbin/ping", ["-c", "4", "-t", "8", "-q", host])
            let result = Self.parsePing(output ?? "", host: host)
            DispatchQueue.main.async {
                self?.pinging = false
                self?.ping = result
                if result.average == nil { self?.error = "Nessuna risposta da \(host)" }
            }
        }
    }

    func runSpeedTest() {
        guard !testingSpeed else { return }
        testingSpeed = true
        error = nil
        queue.async { [weak self] in
            let output = Self.run("/usr/bin/networkQuality", ["-c"])
            let result = output.flatMap(Self.parseSpeed)
            DispatchQueue.main.async {
                self?.testingSpeed = false
                if let result { self?.speed = result } else { self?.error = "Test di velocità non riuscito" }
            }
        }
    }

    static func parsePing(_ output: String, host: String) -> PingResult {
        var result = PingResult(host: host)
        // "round-trip min/avg/max/stddev = 10.1/12.3/15.0/1.9 ms"
        if let line = output.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
           let numbers = line.split(separator: "=").last?.split(separator: " ").first?.split(separator: "/").compactMap({ Double($0) }),
           numbers.count >= 3 {
            result.minimum = numbers[0]
            result.average = numbers[1]
            result.maximum = numbers[2]
        }
        // "4 packets transmitted, 4 packets received, 0.0% packet loss"
        if let line = output.split(separator: "\n").first(where: { $0.contains("packet loss") }),
           let part = line.split(separator: ",").first(where: { $0.contains("packet loss") }),
           let value = Double(part.trimmingCharacters(in: .whitespaces).split(separator: "%").first ?? "") {
            result.loss = value / 100
        }
        return result
    }

    static func parseSpeed(_ output: String) -> SpeedResult? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        let result = SpeedResult(download: number("dl_throughput"), upload: number("ul_throughput"),
                                 responsiveness: number("responsiveness") ?? number("dl_responsiveness"), date: Date())
        return result.download == nil && result.upload == nil ? nil : result
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
