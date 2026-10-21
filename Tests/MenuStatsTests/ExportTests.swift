import XCTest
@testable import MenuStats

final class ExportTests: XCTestCase {
    func testHistoryCSVHasOneRowPerMinuteInReadableUnits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("menustats-csv-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        store.record([.cpu: 0.25, .netDown: 2_000, .cpuTemp: 61.5])

        let lines = store.csv().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(header.first, "Data e ora")
        XCTAssertEqual(header.count, Metric.allCases.count + 1)
        let row = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(row.count, header.count)
        func value(_ metric: Metric) -> String { row[header.firstIndex(of: metric.csvHeader)!] }
        XCTAssertEqual(value(.cpu), "25.00")
        XCTAssertEqual(value(.netDown), "2.00")
        XCTAssertEqual(value(.cpuTemp), "61.50")
        XCTAssertEqual(value(.fan), "", "metrics without samples stay empty")
    }

    func testEmptyHistoryCSVHasOnlyTheHeader() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("menustats-csv-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(HistoryStore(fileURL: url).csv().split(separator: "\n").count, 1)
    }

    func testBackupKeepsOnlyMenuStatsKeys() {
        let values: [String: Any] = [
            "cpuStyle": "graph", "enabledModules": ["cpu", "memory"], "layout": "combined",
            "NSWindow Frame SettingsWindow": "0 0 820 600", "AppleLanguages": ["it"], "com.apple.something": 1,
            "menubarFitGeometry": [1, 2], "MenuStatsBackupVersion": 1,
        ]
        XCTAssertEqual(Set(SettingsBackup.ownValues(values).keys), ["cpuStyle", "enabledModules", "layout"])
    }
}
