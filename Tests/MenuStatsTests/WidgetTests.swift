import SwiftUI
import XCTest
@testable import MenuStatsWidgetUI

final class WidgetDataTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)/widget.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var data = WidgetData.sample
        data.updated = Date(timeIntervalSince1970: 1_800_000_000)
        data.save(to: url)
        XCTAssertEqual(WidgetData.load(from: url), data)
    }

    func testLoadMissingOrCorruptFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        XCTAssertNil(WidgetData.load(from: url))
        try Data("{not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(WidgetData.load(from: url))
    }

    func testSharedFileIsInTheRealHomeFolder() {
        XCTAssertTrue(WidgetData.fileURL.path.hasSuffix("/Library/Application Support/MenuStats/widget.json"))
        XCTAssertFalse(WidgetData.fileURL.path.contains("/Containers/"))
    }

    func testOnlySlowChangingElements() {
        // WidgetKit redraws every few minutes: fast values (CPU, network, temperatures, fans) stay out of widgets.
        XCTAssertEqual(WidgetElement.allCases, [.overview, .memory, .disk, .battery, .weather])
        for element in WidgetElement.allCases { XCTAssertEqual(element.sizes, [.small, .medium], element.title) }
    }

    func testDecodesSnapshotsFromOlderVersions() throws {
        // A 1.3.0 snapshot still has CPU, network and temperature fields: they are ignored, not an error.
        let json = #"{"updated":1800000000,"fahrenheit":false,"chip":"Apple M3 Pro","fans":[],"cpu":{"total":0.2},"#
            + #""memory":{"used":1,"total":2,"app":1,"wired":0,"compressed":0,"pressure":1,"history":[]}}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try XCTUnwrap(WidgetData.load(from: url))
        XCTAssertEqual(data.memory?.fraction, 0.5)
        XCTAssertNil(data.battery)
    }
}

final class ElementSummaryTests: XCTestCase {
    private let data = WidgetData.sample

    func testSummariesFromSampleData() throws {
        let memory = try XCTUnwrap(ElementSummary(element: .memory, data: data))
        XCTAssertEqual(memory.value, "69") // 12.4 of 18 GB
        XCTAssertEqual(memory.unit, "%")
        XCTAssertEqual(memory.rows.count, 4)
        XCTAssertNotNil(memory.bar)

        let disk = try XCTUnwrap(ElementSummary(element: .disk, data: data))
        XCTAssertEqual(disk.value, "121")
        XCTAssertEqual(disk.unit, "GB")
        XCTAssertEqual(disk.gaugeLabel, "76%")
        XCTAssertEqual(disk.rows.first?.value, "373 GB")

        let battery = try XCTUnwrap(ElementSummary(element: .battery, data: data))
        XCTAssertEqual(battery.value, "78")
        XCTAssertTrue(battery.caption.contains("5 h 12 min"))
        XCTAssertEqual(battery.rows.map(\.label), ["Salute", "Cicli", "Consumo"])
    }

    func testMemoryPressureColors() throws {
        var data = data
        data.memory?.pressure = 4
        XCTAssertEqual(ElementSummary(element: .memory, data: data)?.color, WidgetPalette.red)
        data.memory?.pressure = 2
        XCTAssertEqual(ElementSummary(element: .memory, data: data)?.color, WidgetPalette.orange)
    }

    func testBatteryCaptions() throws {
        var data = data
        data.battery?.charging = true
        data.battery?.pluggedIn = true
        data.battery?.minutesRemaining = 40
        XCTAssertEqual(ElementSummary(element: .battery, data: data)?.caption, "Carica · piena tra 40 min")
        data.battery?.charging = false
        XCTAssertEqual(ElementSummary(element: .battery, data: data)?.caption, "Collegato all'alimentazione")
    }

    func testMissingHardwareGivesNoSummary() {
        var data = data
        data.battery = nil
        data.disk = nil
        XCTAssertNil(ElementSummary(element: .battery, data: data))
        XCTAssertNil(ElementSummary(element: .disk, data: data))
        XCTAssertNil(ElementSummary(element: .weather, data: data), "weather has its own view")
    }

    func testFormatting() {
        XCTAssertEqual(WidgetFormat.percent(0.756), "76%")
        XCTAssertEqual(WeatherSymbol.style("sun.min.fill"), .sun)
        XCTAssertEqual(WeatherSymbol.style("moon.stars.fill"), .moon)
        XCTAssertEqual(WeatherSymbol.style("cloud.sun.rain.fill"), .multicolor)
        XCTAssertEqual(WidgetFormat.temperature(100, fahrenheit: true, unit: true), "212°F")
        XCTAssertEqual(WidgetFormat.duration(minutes: 312), "5 h 12 min")
        XCTAssertEqual(WidgetFormat.duration(minutes: 45), "45 min")
    }

    func testSeverityColors() {
        XCTAssertEqual(WidgetPalette.usage(0.5, base: WidgetPalette.blue), WidgetPalette.blue)
        XCTAssertEqual(WidgetPalette.usage(0.8, base: WidgetPalette.blue), WidgetPalette.orange)
        XCTAssertEqual(WidgetPalette.usage(0.95, base: WidgetPalette.blue), WidgetPalette.red)
        XCTAssertEqual(WidgetPalette.battery(0.05, charging: false), WidgetPalette.red)
        XCTAssertEqual(WidgetPalette.battery(0.05, charging: true), WidgetPalette.green)
    }
}

/// Every widget (element × size), with full, partial and no data, renders a non-empty image.
@MainActor
final class WidgetRenderTests: XCTestCase {
    func testEveryWidgetRenders() throws {
        var partial = WidgetData.sample
        partial.battery = nil
        partial.weather = nil
        partial.memory?.history = []
        for data in [WidgetData.sample, partial, nil] as [WidgetData?] {
            for element in WidgetElement.allCases {
                for size in element.sizes {
                    let frame = WidgetMetrics.size(size)
                    let view = MenuStatsWidgetView(element: element, size: size, data: data)
                        .padding(WidgetMetrics.margin)
                        .frame(width: frame.width, height: frame.height)
                        .background(WidgetBackground(element: element))
                    let renderer = ImageRenderer(content: view)
                    let image = try XCTUnwrap(renderer.cgImage, "\(element) \(size)")
                    XCTAssertEqual(image.width, Int(frame.width * renderer.scale))
                    XCTAssertEqual(image.height, Int(frame.height * renderer.scale))
                }
            }
        }
    }
}
