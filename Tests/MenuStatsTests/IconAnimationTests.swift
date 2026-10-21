import XCTest
@testable import MenuStats

final class IconAnimationTests: XCTestCase {
    func testAnimationFollowsThePowerSource() {
        XCTAssertTrue(IconAnimation.onPower.allowsMotion(lowPowerMode: false, onACPower: true))
        XCTAssertFalse(IconAnimation.onPower.allowsMotion(lowPowerMode: false, onACPower: false), "a batteria resta ferma")
        XCTAssertTrue(IconAnimation.onPower.allowsMotion(lowPowerMode: false, onACPower: nil), "i Mac senza batteria sono sempre collegati")
        XCTAssertTrue(IconAnimation.always.allowsMotion(lowPowerMode: false, onACPower: false))
        XCTAssertFalse(IconAnimation.never.allowsMotion(lowPowerMode: false, onACPower: true))
    }

    func testLowPowerModeStopsEveryAnimation() {
        for choice in IconAnimation.allCases {
            XCTAssertFalse(choice.allowsMotion(lowPowerMode: true, onACPower: true), choice.rawValue)
        }
    }
}
