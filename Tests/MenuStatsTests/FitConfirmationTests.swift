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

    func testRestoreBacksOffWhenAWiderBarDoesNotFit() {
        var fit = FitConfirmation()
        XCTAssertEqual(fit.restoreDelay, FitConfirmation.firstRestoreDelay)
        fit.beganRestore()
        fit.layoutChanged(at: t0, signature: 1)
        _ = fit.observe(hidden: true, signature: 2, at: t0.addingTimeInterval(2))
        XCTAssertEqual(fit.observe(hidden: true, signature: 2, at: t0.addingTimeInterval(3)), .shrink)
        XCTAssertEqual(fit.restoreDelay, 20)
        // The next attempt fails too: 40, and the delay is capped.
        fit.beganRestore()
        fit.layoutChanged(at: t0.addingTimeInterval(30), signature: 3)
        _ = fit.observe(hidden: true, signature: 4, at: t0.addingTimeInterval(32))
        XCTAssertEqual(fit.observe(hidden: true, signature: 4, at: t0.addingTimeInterval(33)), .shrink)
        XCTAssertEqual(fit.restoreDelay, 40)
    }

    func testRestoreDelayResetsWhenTheWiderBarFits() {
        var fit = FitConfirmation()
        fit.beganRestore()
        fit.layoutChanged(at: t0, signature: 1)
        _ = fit.observe(hidden: true, signature: 2, at: t0.addingTimeInterval(2))
        _ = fit.observe(hidden: true, signature: 2, at: t0.addingTimeInterval(3)) // did not fit: 20
        XCTAssertEqual(fit.restoreDelay, 20)
        fit.beganRestore()
        fit.layoutChanged(at: t0.addingTimeInterval(30), signature: 3)
        XCTAssertEqual(fit.observe(hidden: false, signature: 4, at: t0.addingTimeInterval(32)), .fine)
        XCTAssertEqual(fit.restoreDelay, FitConfirmation.firstRestoreDelay)
    }
}
