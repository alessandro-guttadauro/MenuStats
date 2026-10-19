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

    func testEveryElementOffersItsSizes() {
        for element in WidgetElement.allCases {
            XCTAssertTrue(element.sizes.contains(.small) && element.sizes.contains(.medium), element.title)
            XCTAssertEqual(element.sizes.contains(.large), element == .overview, element.title)
        }
    }
}

final class ElementSummaryTests: XCTestCase {
    private let data = WidgetData.sample

    func testSummariesFromSampleData() throws {
        let cpu = try XCTUnwrap(ElementSummary(element: .cpu, data: data))
        XCTAssertEqual(cpu.value, "24")
        XCTAssertEqual(cpu.unit, "%")
        XCTAssertEqual(cpu.fraction ?? 0, 0.24, accuracy: 0.0001)

        let memory = try XCTUnwrap(ElementSummary(element: .memory, data: data))
        XCTAssertEqual(memory.value, "69") // 12.4 of 18 GB
        XCTAssertEqual(memory.rows.count, 4)

        let disk = try XCTUnwrap(ElementSummary(element: .disk, data: data))
        XCTAssertEqual(disk.value, "121")
        XCTAssertEqual(disk.unit, "GB")
        XCTAssertEqual(disk.gaugeLabel, "76%")

        let temperature = try XCTUnwrap(ElementSummary(element: .temperature, data: data))
        XCTAssertEqual(temperature.value, "47°")

        let fans = try XCTUnwrap(ElementSummary(element: .fans, data: data))
        XCTAssertEqual(fans.value, "2400")
        XCTAssertEqual(fans.rows.count, 2)

        let battery = try XCTUnwrap(ElementSummary(element: .battery, data: data))
        XCTAssertEqual(battery.value, "78")
        XCTAssertTrue(battery.caption.contains("5 h 12 min"))
    }

    func testFahrenheit() throws {
        var data = data
        data.fahrenheit = true
        XCTAssertEqual(ElementSummary(element: .temperature, data: data)?.value, "117°")
    }

    func testMissingHardwareGivesNoSummary() {
        var data = data
        data.battery = nil
        data.fans = []
        data.temperature = nil
        XCTAssertNil(ElementSummary(element: .battery, data: data))
        XCTAssertNil(ElementSummary(element: .fans, data: data))
        XCTAssertNil(ElementSummary(element: .temperature, data: data))
    }

    func testFormatting() {
        XCTAssertEqual(WidgetFormat.rateParts(0).value, "0")
        XCTAssertEqual(WidgetFormat.rateParts(2_400_000).value, "2.4")
        XCTAssertEqual(WidgetFormat.rateParts(2_400_000).unit, "MB/s")
        XCTAssertEqual(WidgetFormat.rateParts(310_000).unit, "KB/s")
        XCTAssertEqual(WidgetFormat.temperature(100, fahrenheit: true, unit: true), "212°F")
        XCTAssertEqual(WidgetFormat.duration(minutes: 312), "5 h 12 min")
        XCTAssertEqual(WidgetFormat.duration(minutes: 45), "45 min")
    }

    func testSeverityColors() {
        XCTAssertEqual(WidgetPalette.usage(0.5, base: WidgetPalette.blue), WidgetPalette.blue)
        XCTAssertEqual(WidgetPalette.usage(0.8, base: WidgetPalette.blue), WidgetPalette.orange)
        XCTAssertEqual(WidgetPalette.usage(0.95, base: WidgetPalette.blue), WidgetPalette.red)
        XCTAssertEqual(WidgetPalette.temperature(95), WidgetPalette.red)
    }
}

/// Every widget (element × size), with full, partial and no data, renders a non-empty image.
@MainActor
final class WidgetRenderTests: XCTestCase {
    func testEveryWidgetRenders() throws {
        var partial = WidgetData.sample
        partial.battery = nil
        partial.fans = []
        partial.weather = nil
        partial.cpu?.history = []
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
