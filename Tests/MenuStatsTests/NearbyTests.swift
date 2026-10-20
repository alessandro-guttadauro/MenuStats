import XCTest
@testable import MenuStats

final class NearbyTests: XCTestCase {
    func testDistanceGrowsAsTheSignalWeakens() {
        let close = NearbyMath.distance(rssi: -50)
        let room = NearbyMath.distance(rssi: -70)
        let far = NearbyMath.distance(rssi: -90)
        XCTAssertLessThan(close, room)
        XCTAssertLessThan(room, far)
        // -59 dBm is the assumed signal at one meter.
        XCTAssertEqual(NearbyMath.distance(rssi: -59), 1, accuracy: 0.001)
    }

    func testSmoothingDampensASingleSpike() {
        XCTAssertEqual(NearbyMath.smooth(nil, -60), -60)
        XCTAssertEqual(NearbyMath.smooth(-60, -90), -75, accuracy: 0.001)
    }

    func testDistanceLabels() {
        XCTAssertEqual(NearbyMath.label(forDistance: 0.4), "< 1 m")
        XCTAssertEqual(NearbyMath.label(forDistance: 2.4), "≈ 2 m")
        XCTAssertEqual(NearbyMath.label(forDistance: 12), "≈ 10 m")
        XCTAssertEqual(NearbyMath.label(forDistance: 80), "> 30 m")
    }

    func testIcons() {
        XCTAssertEqual(NearbyMath.symbol(name: "Daniele’s AirPods Pro", kind: "Headphones"), "airpodspro")
        XCTAssertEqual(NearbyMath.symbol(name: "Daniele’s Phone", kind: nil), "iphone")
        XCTAssertEqual(NearbyMath.symbol(name: "iPad", kind: nil), "ipad")
        XCTAssertEqual(NearbyMath.symbol(name: "Apple Watch di Anna", kind: nil), "applewatch")
        XCTAssertEqual(NearbyMath.symbol(name: "Magic Mouse", kind: "Mouse"), "computermouse")
        XCTAssertEqual(NearbyMath.symbol(name: "Magic Keyboard", kind: "Keyboard"), "keyboard")
        XCTAssertEqual(NearbyMath.symbol(name: "Qualcosa", kind: nil), "dot.radiowaves.left.and.right")
    }

    private let profiler = """
    {"SPBluetoothDataType": [{
      "device_connected": [
        {"Cuffie": {"device_address": "AA:01", "device_minorType": "Headphones", "device_rssi": -39}},
        {"Tastiera": {"device_address": "AA:02", "device_minorType": "Keyboard"}}
      ],
      "device_not_connected": [
        {"Telefono": {"device_address": "AA:03", "device_rssi": "-77"}},
        {"Mouse": {"device_address": "AA:04", "device_minorType": "Mouse"}},
        {"Rotto": {"device_rssi": -50}},
        {"Senza segnale": {"device_address": "AA:05", "device_rssi": 127}}
      ]
    }]}
    """

    func testParsesDevicesAndSignalFromSystemProfiler() {
        let entries = NearbyDeviceReader.parse(Data(profiler.utf8))
        XCTAssertEqual(entries.count, 5) // the one without an address is skipped
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["Cuffie"]?.rssi, -39)
        XCTAssertEqual(byName["Cuffie"]?.connected, true)
        XCTAssertNil(byName["Tastiera"]?.rssi)
        XCTAssertEqual(byName["Telefono"]?.rssi, -77) // numbers sent as text still count
        XCTAssertEqual(byName["Telefono"]?.connected, false)
        XCTAssertNil(byName["Senza segnale"]?.rssi) // 127 means "no reading"
        XCTAssertTrue(NearbyDeviceReader.parse(Data("not json".utf8)).isEmpty)
    }

    func testOnlyKnownDevicesAreEverListed() {
        // Everything comes from the list macOS keeps for this user: nothing here scans for strangers.
        let names = NearbyDeviceReader.parse(Data(profiler.utf8)).map(\.name)
        XCTAssertEqual(Set(names), ["Cuffie", "Tastiera", "Telefono", "Mouse", "Senza segnale"])
    }

    func testRadarPlacementIsMonotonicAndInsideTheCircle() {
        let samples = [0.2, 0.9, 1, 2, 3, 6, 10, 50].map(NearbyRadar.radius(forDistance:))
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertTrue(samples.allSatisfy { $0 > 0 && $0 <= 1 })
        XCTAssertEqual(NearbyRadar.radius(forDistance: 3), 0.66, accuracy: 0.001)
        XCTAssertEqual(NearbyRadar.radius(forDistance: 10), 1, accuracy: 0.001)
    }

    func testAnglesSpreadDevicesEvenly() {
        let angles = NearbyRadar.angles(for: ["B", "A", "C"])
        XCTAssertEqual(angles.count, 3)
        XCTAssertEqual(angles["A"], -Double.pi / 2)
        XCTAssertEqual(try XCTUnwrap(angles["B"]) - XCTUnwrap(angles["A"]), 2 * .pi / 3, accuracy: 1e-9)
        XCTAssertEqual(NearbyRadar.angles(for: ["B", "A", "C"]), NearbyRadar.angles(for: ["C", "A", "B"]))
        XCTAssertTrue(NearbyRadar.angles(for: []).isEmpty)
    }
}
