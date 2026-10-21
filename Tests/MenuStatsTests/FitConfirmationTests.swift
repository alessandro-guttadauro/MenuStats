import XCTest
@testable import MenuStats

final class FitConfirmationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testAVisibleItemNeedsNothing() {
        var fit = FitConfirmation()
        XCTAssertEqual(fit.observe(hidden: false, at: t0), .fine)
    }

    func testReadingsRightAfterAChangeAreIgnored() {
        var fit = FitConfirmation()
        fit.layoutChanged(at: t0)
        // macOS reports a new item as hidden before it is laid out: wait, do not shrink.
        guard case .wait(let seconds) = fit.observe(hidden: true, at: t0.addingTimeInterval(0.3)) else { return XCTFail() }
        XCTAssertEqual(seconds, FitConfirmation.settle - 0.3 + 0.1, accuracy: 0.001)
    }

    func testShrinksOnlyAfterTheItemStaysHidden() {
        var fit = FitConfirmation()
        XCTAssertEqual(fit.observe(hidden: true, at: t0), .wait(0.5))
        XCTAssertEqual(fit.observe(hidden: true, at: t0.addingTimeInterval(0.5)), .wait(0.5))
        XCTAssertEqual(fit.observe(hidden: true, at: t0.addingTimeInterval(0.9)), .shrink)
    }

    func testAHiddenBlipThatClearsDoesNotShrink() {
        var fit = FitConfirmation()
        XCTAssertEqual(fit.observe(hidden: true, at: t0), .wait(0.5))
        XCTAssertEqual(fit.observe(hidden: false, at: t0.addingTimeInterval(0.4)), .fine)
        // A later blip starts counting again from zero.
        XCTAssertEqual(fit.observe(hidden: true, at: t0.addingTimeInterval(5)), .wait(0.5))
        XCTAssertEqual(fit.observe(hidden: true, at: t0.addingTimeInterval(5.5)), .wait(0.5))
    }

    func testDoesNotShrinkAgainUntilTheLayoutHasMoved() {
        // The frames seen in the field: after a shrink macOS kept reporting the old position for seconds, and the bar
        // lost another module for nothing.
        var fit = FitConfirmation()
        fit.layoutChanged(at: t0, signature: 100)
        for step in stride(from: 1.2, through: 4.8, by: 0.4) {
            let verdict = fit.observe(hidden: true, signature: 100, at: t0.addingTimeInterval(step))
            XCTAssertNotEqual(verdict, .shrink, "shrank at \(step) with the layout unchanged")
        }
        // Once the layout moves and still looks hidden, it can shrink after the usual confirmation.
        XCTAssertEqual(fit.observe(hidden: true, signature: 120, at: t0.addingTimeInterval(5.0)), .wait(0.5))
        XCTAssertEqual(fit.observe(hidden: true, signature: 120, at: t0.addingTimeInterval(5.9)), .shrink)
    }

    func testAnUnchangedLayoutIsTrustedAfterTheLagTimeout() {
        var fit = FitConfirmation()
        fit.layoutChanged(at: t0, signature: 100)
        XCTAssertEqual(fit.observe(hidden: true, signature: 100, at: t0.addingTimeInterval(5.5)), .wait(0.5))
        XCTAssertEqual(fit.observe(hidden: true, signature: 100, at: t0.addingTimeInterval(6.4)), .shrink)
    }

    func testRestoreWaitsLongerAfterEachWiderBarThatDoesNotFit() {
        var fit = FitConfirmation()
        XCTAssertEqual(fit.restoreDelay, FitConfirmation.firstRestoreDelay)
        var start = t0
        for expected: TimeInterval in [60, 120, 240, 480, 600, 600] {
            fit.beganRestore(at: start)
            fit.layoutChanged(at: start, signature: 1)
            _ = fit.observe(hidden: true, signature: 2, at: start.addingTimeInterval(2))
            XCTAssertEqual(fit.observe(hidden: true, signature: 2, at: start.addingTimeInterval(3)), .shrink)
            XCTAssertEqual(fit.restoreDelay, expected, "fewer tries: the bar would flicker")
            start = start.addingTimeInterval(100)
        }
        fit.roomMayHaveChanged()
        XCTAssertEqual(fit.restoreDelay, FitConfirmation.firstRestoreDelay)
    }

    func testRestoreDelayStaysShortWhenTheWiderBarFits() {
        var fit = FitConfirmation()
        fit.beganRestore(at: t0)
        fit.layoutChanged(at: t0, signature: 1)
        XCTAssertEqual(fit.observe(hidden: false, signature: 2, at: t0.addingTimeInterval(2)), .fine)
        XCTAssertTrue(fit.confirmingRestore)
        XCTAssertEqual(fit.observe(hidden: false, signature: 2, at: t0.addingTimeInterval(31)), .fine)
        XCTAssertFalse(fit.confirmingRestore)
        XCTAssertEqual(fit.restoreDelay, FitConfirmation.firstRestoreDelay)
    }

    func testAWiderBarHiddenSecondsAfterShowingCountsAsNotFitting() {
        // macOS shows the wider bar, then hides it a few seconds later.
        var fit = FitConfirmation()
        fit.beganRestore(at: t0)
        fit.layoutChanged(at: t0, signature: 1)
        XCTAssertEqual(fit.observe(hidden: false, signature: 2, at: t0.addingTimeInterval(2)), .fine)
        _ = fit.observe(hidden: true, signature: 2, at: t0.addingTimeInterval(8))
        XCTAssertEqual(fit.observe(hidden: true, signature: 2, at: t0.addingTimeInterval(9)), .shrink)
        XCTAssertEqual(fit.restoreDelay, FitConfirmation.failedRestoreDelay)
    }

    func testAReadingThatStaysHiddenCostsOnlyAFewShrinks() {
        // The field case: the item looked hidden at every width, because something else covered the bar.
        var fit = FitConfirmation()
        var shrinks = 0
        var signature = 1.0
        var now = t0
        while now < t0.addingTimeInterval(15) {
            switch fit.observe(hidden: true, signature: signature, at: now) {
            case .shrink:
                shrinks += 1
                signature += 10 // the layout does move after each shrink
                fit.layoutChanged(at: now, signature: signature - 5)
            default: break
            }
            now = now.addingTimeInterval(0.25)
        }
        XCTAssertEqual(shrinks, FitConfirmation.shrinkBudget)
    }

    func testShrinksAreEarnedBackWithTimeAndAVisibleReadingResetsThem() {
        var fit = FitConfirmation()
        var now = t0
        func shrinkNow() -> Bool {
            fit.layoutChanged(at: now.addingTimeInterval(-10), signature: 1)
            _ = fit.observe(hidden: true, signature: 2, at: now)
            now = now.addingTimeInterval(1)
            return fit.observe(hidden: true, signature: 2, at: now) == .shrink
        }
        XCTAssertTrue(shrinkNow())
        now = now.addingTimeInterval(1)
        XCTAssertTrue(shrinkNow())
        now = now.addingTimeInterval(1)
        XCTAssertFalse(shrinkNow()) // out of shrinks
        now = now.addingTimeInterval(FitConfirmation.shrinkRefill)
        XCTAssertTrue(shrinkNow()) // one earned back
        XCTAssertEqual(fit.observe(hidden: false, at: now.addingTimeInterval(1)), .fine)
        now = now.addingTimeInterval(2)
        XCTAssertTrue(shrinkNow())
        now = now.addingTimeInterval(1)
        XCTAssertTrue(shrinkNow()) // a visible reading restored the whole budget
    }
}
