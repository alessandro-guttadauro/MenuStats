import Foundation
import SQLite3

enum Metric: String, CaseIterable {
    case cpu, cpuUser, cpuSystem, memory, swap, netDown, netUp, diskRead, diskWrite
    case cpuTemp, ssdTemp, fan, power, battery, batteryPower
}

extension Metric {
    /// Column title in the CSV export, with the unit of `csvValue`.
    var csvHeader: String {
        switch self {
        case .cpu: "CPU (%)"
        case .cpuUser: "CPU utente (%)"
        case .cpuSystem: "CPU sistema (%)"
        case .memory: "Memoria (%)"
        case .swap: "Swap (MB)"
        case .netDown: "Download (KB/s)"
        case .netUp: "Upload (KB/s)"
        case .diskRead: "Disco lettura (KB/s)"
        case .diskWrite: "Disco scrittura (KB/s)"
        case .cpuTemp: "Temperatura CPU (°C)"
        case .ssdTemp: "Temperatura SSD (°C)"
        case .fan: "Ventole (giri/min)"
        case .power: "Consumo sistema (W)"
        case .battery: "Batteria (%)"
        case .batteryPower: "Batteria (W)"
        }
    }

    /// Stored value (fractions, bytes, bytes per second) converted to the CSV unit.
    func csvValue(_ value: Double) -> Double {
        switch self {
        case .cpu, .cpuUser, .cpuSystem, .memory, .battery: value * 100
        case .swap: value / 1_000_000
        case .netDown, .netUp, .diskRead, .diskWrite: value / 1_000
        case .cpuTemp, .ssdTemp, .fan, .power, .batteryPower: value
        }
    }
}

/// Chart time range. `live` comes from the in-memory buffer, the others from SQLite.
enum HistoryRange: Int, CaseIterable, Identifiable {
    case live, hour, day, week
    var id: Int { rawValue }

    var label: String { ["Live", "1 h", "24 h", "7 g"][rawValue] }
    var spanMinutes: Int { [5, 60, 1440, 10_080][rawValue] }
    /// Resolution of one plotted point.
    var bucketMinutes: Int { [1, 1, 10, 60][rawValue] }
}

struct HistoryPoint {
    /// Start of the bucket, in minutes since 1970.
    var minute: Int
    var value: Double
}

/// Per-minute averages of every metric in SQLite (~/Library/Application Support/MenuStats),
/// kept for 8 days. Samples are accumulated in memory and written once per minute.
final class HistoryStore {
    static let retentionMinutes = 8 * 1440

    private var db: OpaquePointer?
    private var accumulator: [Metric: (sum: Double, count: Int)] = [:]
    private var accumulatorMinute = HistoryStore.currentMinute()
    private var lastPrune = 0

    init(fileURL: URL = HistoryStore.defaultURL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else {
            NSLog("MenuStats: cannot open history database at \(fileURL.path)")
            db = nil
            return
        }
        execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS samples (
                metric TEXT NOT NULL,
                minute INTEGER NOT NULL,
                value REAL NOT NULL,
                PRIMARY KEY (metric, minute)
            ) WITHOUT ROWID;
            """)
        prune()
    }

    deinit {
        flush()
        sqlite3_close(db)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuStats/history.sqlite")
    }

    static func currentMinute(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    func record(_ values: [Metric: Double]) {
        let minute = Self.currentMinute()
        if minute != accumulatorMinute {
            flush()
            accumulatorMinute = minute
        }
        for (metric, value) in values where value.isFinite {
            let entry = accumulator[metric] ?? (0, 0)
            accumulator[metric] = (entry.sum + value, entry.count + 1)
        }
    }

    /// Bucketed averages for the range, including the minute still being accumulated.
    func series(_ metric: Metric, range: HistoryRange) -> [HistoryPoint] {
        let bucket = range.bucketMinutes
        let start = Self.currentMinute() - range.spanMinutes
        var points: [HistoryPoint] = []

        var statement: OpaquePointer?
        let sql = "SELECT (minute / ?1) * ?1 AS b, AVG(value) FROM samples WHERE metric = ?2 AND minute >= ?3 GROUP BY b ORDER BY b"
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, Int64(bucket))
            sqlite3_bind_text(statement, 2, metric.rawValue, -1, Self.transient)
            sqlite3_bind_int64(statement, 3, Int64(start))
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(HistoryPoint(minute: Int(sqlite3_column_int64(statement, 0)),
                                           value: sqlite3_column_double(statement, 1)))
            }
        }
        sqlite3_finalize(statement)

        if let pending = accumulator[metric], pending.count > 0 {
            let value = pending.sum / Double(pending.count)
            let pendingBucket = accumulatorMinute / bucket * bucket
            if let last = points.last, last.minute == pendingBucket {
                // Blend into the stored part of the same bucket (equal weight per stored minute).
                let storedMinutes = Double(min(bucket, max(1, accumulatorMinute - pendingBucket)))
                points[points.count - 1].value = (last.value * storedMinutes + value) / (storedMinutes + 1)
            } else {
                points.append(HistoryPoint(minute: pendingBucket, value: value))
            }
        }
        return points
    }

    /// Every stored minute as CSV, one row per minute and one column per metric, in readable units.
    func csv() -> String {
        flush()
        var rows: [Int: [Metric: Double]] = [:]
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT metric, minute, value FROM samples ORDER BY minute", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqlite3_column_text(statement, 0), let metric = Metric(rawValue: String(cString: name)) else { continue }
                rows[Int(sqlite3_column_int64(statement, 1)), default: [:]][metric] = sqlite3_column_double(statement, 2)
            }
        }
        sqlite3_finalize(statement)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let metrics = Metric.allCases
        var lines = [(["Data e ora"] + metrics.map(\.csvHeader)).joined(separator: ",")]
        for minute in rows.keys.sorted() {
            let values = rows[minute]!
            let date = formatter.string(from: Date(timeIntervalSince1970: Double(minute) * 60))
            lines.append(([date] + metrics.map { metric in
                values[metric].map { String(format: "%.2f", metric.csvValue($0)) } ?? ""
            }).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func clear() {
        accumulator.removeAll()
        execute("DELETE FROM samples")
    }

    private func flush() {
        guard db != nil, !accumulator.isEmpty else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples (metric, minute, value) VALUES (?1, ?2, ?3)", -1, &statement, nil) == SQLITE_OK
        else { return }
        execute("BEGIN")
        for (metric, entry) in accumulator where entry.count > 0 {
            sqlite3_bind_text(statement, 1, metric.rawValue, -1, Self.transient)
            sqlite3_bind_int64(statement, 2, Int64(accumulatorMinute))
            sqlite3_bind_double(statement, 3, entry.sum / Double(entry.count))
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
        execute("COMMIT")
        sqlite3_finalize(statement)
        accumulator.removeAll()

        if accumulatorMinute - lastPrune >= 60 { prune() }
    }

    private func prune() {
        let cutoff = Self.currentMinute() - Self.retentionMinutes
        execute("DELETE FROM samples WHERE minute < \(cutoff)")
        lastPrune = Self.currentMinute()
    }

    private func execute(_ sql: String) {
        guard db != nil else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("MenuStats: SQLite error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

extension Snapshot {
    /// The values recorded into the history each refresh.
    var historyValues: [Metric: Double] {
        var values: [Metric: Double] = [:]
        values[.cpu] = cpu?.total
        values[.cpuUser] = cpu?.user
        values[.cpuSystem] = cpu?.system
        values[.memory] = memory?.usedFraction
        values[.swap] = memory.map { Double($0.swapUsed) }
        values[.netDown] = network?.downloadRate
        values[.netUp] = network?.uploadRate
        values[.diskRead] = disk?.readRate
        values[.diskWrite] = disk?.writeRate
        values[.cpuTemp] = cpuTemperature
        values[.ssdTemp] = ssdTemperature
        values[.fan] = maxFanRPM
        values[.power] = smc?.systemPower
        values[.battery] = battery?.percent
        values[.batteryPower] = battery?.watts
        return values
    }
}
