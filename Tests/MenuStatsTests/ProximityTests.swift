import XCTest
@testable import MenuStats

final class ProximityTests: XCTestCase {
    private let phone = "AA:01", watch = "AA:02"
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func step(_ logic: inout ProximityLogic, present: Set<String>, watched: Set<String>? = nil, all: Bool = false,
                      grace: TimeInterval = 30, at seconds: TimeInterval, canLock: Bool = true) -> Bool {
        logic.evaluate(present: present, watched: watched ?? [phone], requiresAll: all, grace: grace,
                       now: start.addingTimeInterval(seconds), canLock: canLock)
    }

    func testNeverLocksForADeviceItHasNotSeen() {
        var logic = ProximityLogic()
        XCTAssertFalse(step(&logic, present: [], at: 0))
        XCTAssertFalse(step(&logic, present: [], at: 600))
    }

    func testLocksOnlyAfterTheGracePeriod() {
        var logic = ProximityLogic()
        XCTAssertFalse(step(&logic, present: [phone], at: 0))
        XCTAssertFalse(step(&logic, present: [], at: 10))
        XCTAssertFalse(step(&logic, present: [], at: 29))
        XCTAssertTrue(step(&logic, present: [], at: 31))
    }

    func testABriefDropoutDoesNotLock() {
        var logic = ProximityLogic()
        _ = step(&logic, present: [phone], at: 0)
        XCTAssertFalse(step(&logic, present: [], at: 20))
        XCTAssertFalse(step(&logic, present: [phone], at: 25)) // back before the grace period ended
        XCTAssertFalse(step(&logic, present: [], at: 45))
        XCTAssertTrue(step(&logic, present: [], at: 56))
    }

    func testLocksOnceAndRearmsOnlyWhenTheDeviceReturns() {
        var logic = ProximityLogic()
        _ = step(&logic, present: [phone], at: 0)
        XCTAssertTrue(step(&logic, present: [], at: 40))
        // The user unlocks by hand with the phone still away: no lock loop.
        XCTAssertFalse(step(&logic, present: [], at: 50))
        XCTAssertFalse(step(&logic, present: [], at: 500))
        // The phone comes back, then leaves again: locks again.
        XCTAssertFalse(step(&logic, present: [phone], at: 510))
        XCTAssertTrue(step(&logic, present: [], at: 560))
    }

    func testDoesNotLockWhenTheScreenIsAlreadyLockedOrOff() {
        var logic = ProximityLogic()
        _ = step(&logic, present: [phone], at: 0)
        XCTAssertFalse(step(&logic, present: [], at: 100, canLock: false))
        // Once the screen is usable again with the device still away, it locks.
        XCTAssertTrue(step(&logic, present: [], at: 110, canLock: true))
    }

    func testAnyOrAllOfSeveralDevices() {
        let watched: Set<String> = [phone, watch]
        var any = ProximityLogic()
        _ = step(&any, present: [phone, watch], watched: watched, at: 0)
        XCTAssertFalse(step(&any, present: [watch], watched: watched, at: 10))
        XCTAssertTrue(step(&any, present: [watch], watched: watched, at: 40)) // the phone is away

        var all = ProximityLogic()
        _ = step(&all, present: [phone, watch], watched: watched, all: true, at: 0)
        XCTAssertFalse(step(&all, present: [watch], watched: watched, all: true, at: 40)) // the watch is still here
        XCTAssertTrue(step(&all, present: [], watched: watched, all: true, at: 80))
    }

    func testRestartGraceAfterSleep() {
        var logic = ProximityLogic()
        _ = step(&logic, present: [phone], at: 0)
        logic.restartGrace(now: start.addingTimeInterval(3600)) // the Mac slept for an hour
        XCTAssertFalse(step(&logic, present: [], at: 3610))
        XCTAssertTrue(step(&logic, present: [], at: 3640))
    }

    func testReadingIntervalIsBoundedByTheGracePeriod() {
        XCTAssertEqual(ProximityLock.interval(forGrace: 2), 1)
        XCTAssertEqual(ProximityLock.interval(forGrace: 5), 5.0 / 3, accuracy: 0.001)
        XCTAssertEqual(ProximityLock.interval(forGrace: 15), 5)
        XCTAssertEqual(ProximityLock.interval(forGrace: 60), 20)
        XCTAssertEqual(ProximityLock.interval(forGrace: 5000), 60)
    }

    func testLockFollowsTheSettingsAndOnlyWatchedDevices() {
        let settings = Settings.shared
        let saved = (settings.proximityLockEnabled, settings.proximityLockDevices, settings.proximityLockGrace, settings.proximityLockRequiresAll)
        addTeardownBlock {
            settings.proximityLockEnabled = saved.0
            settings.proximityLockDevices = saved.1
            settings.proximityLockGrace = saved.2
            settings.proximityLockRequiresAll = saved.3
        }
        var locks = 0
        let proximity = ProximityLock(settings: settings, reader: { [] }, lockAction: { locks += 1 }, canLockNow: { true })

        func entry(_ id: String, rssi: Double?, connected: Bool = false) -> NearbyDeviceReader.Entry {
            NearbyDeviceReader.Entry(id: id, name: id, kind: nil, connected: connected, rssi: rssi)
        }
        settings.proximityLockGrace = 15
        settings.proximityLockRequiresAll = false
        settings.proximityLockDevices = [phone: "iPhone"]
        settings.proximityLockEnabled = true

        // A stranger's device in the readings is ignored; only the watched phone counts.
        proximity.handle([entry(phone, rssi: -60), entry("ZZ:99", rssi: -30)], now: start)
        XCTAssertEqual(proximity.presentCount, 1)
        proximity.handle([entry("ZZ:99", rssi: -30)], now: start.addingTimeInterval(10))
        XCTAssertEqual(locks, 0)
        proximity.handle([entry("ZZ:99", rssi: -30)], now: start.addingTimeInterval(20))
        XCTAssertEqual(locks, 1)
        XCTAssertNotNil(proximity.lastLock)
        proximity.handle([], now: start.addingTimeInterval(60))
        XCTAssertEqual(locks, 1)

        // Switched off: nothing happens.
        settings.proximityLockEnabled = false
        proximity.handle([entry(phone, rssi: -60)], now: start.addingTimeInterval(100))
        proximity.handle([], now: start.addingTimeInterval(200))
        XCTAssertEqual(locks, 1)
    }

    func testDistanceLimitCountsAFarDeviceAsAway() {
        let settings = Settings.shared
        let saved = (settings.proximityLockEnabled, settings.proximityLockDevices, settings.proximityLockGrace,
                     settings.proximityLockUseDistance, settings.proximityLockDistance)
        addTeardownBlock {
            settings.proximityLockEnabled = saved.0
            settings.proximityLockDevices = saved.1
            settings.proximityLockGrace = saved.2
            settings.proximityLockUseDistance = saved.3
            settings.proximityLockDistance = saved.4
        }
        var locks = 0
        let proximity = ProximityLock(settings: settings, reader: { [] }, lockAction: { locks += 1 }, canLockNow: { true })
        func entry(rssi: Double?, connected: Bool = false) -> NearbyDeviceReader.Entry {
            NearbyDeviceReader.Entry(id: phone, name: "iPhone", kind: nil, connected: connected, rssi: rssi)
        }
        settings.proximityLockGrace = 5
        settings.proximityLockDevices = [phone: "iPhone"]
        settings.proximityLockUseDistance = true
        settings.proximityLockDistance = 3 // meters
        settings.proximityLockEnabled = true

        // -50 dBm is about 0.6 m: near. The signal then weakens to about 10 m and stays there.
        proximity.handle([entry(rssi: -50)], now: start)
        XCTAssertEqual(proximity.presentCount, 1)
        for second in stride(from: 1.0, through: 10.0, by: 1.0) {
            proximity.handle([entry(rssi: -80)], now: start.addingTimeInterval(second))
        }
        XCTAssertEqual(proximity.presentCount, 0, "far away counts as not near")
        XCTAssertEqual(locks, 1)

        // A connected device with no signal reading is never counted as far.
        locks = 0
        proximity.handle([entry(rssi: -50)], now: start.addingTimeInterval(100))
        proximity.handle([entry(rssi: nil, connected: true)], now: start.addingTimeInterval(110))
        XCTAssertEqual(proximity.presentCount, 1)
        XCTAssertEqual(locks, 0)
    }
}

/// The real lock action and the full ProximityLock path, with the device readings simulated.
final class ScreenLockTests: XCTestCase {
    private let phone = "AA:01"
    private let start = Date(timeIntervalSince1970: 2_000_000)

    func testTheSystemLockFunctionExistsOnThisMacOS() {
        // SystemActions.lockScreen() calls it; without it the lock would fall back to sleeping the display.
        let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        XCTAssertNotNil(handle)
        XCTAssertNotNil(handle.flatMap { dlsym($0, "SACLockScreenImmediate") })
    }

    func testScreenStateIsReadable() {
        XCTAssertNotNil(CGSessionCopyCurrentDictionary(), "the session state used to skip locking a locked screen")
    }

    private func entry(_ id: String, rssi: Double?) -> NearbyDeviceReader.Entry {
        NearbyDeviceReader.Entry(id: id, name: id, kind: nil, connected: false, rssi: rssi)
    }

    private func withLockSettings(_ body: (Settings) -> Void) {
        let settings = Settings.shared
        let saved = (settings.proximityLockEnabled, settings.proximityLockDevices, settings.proximityLockGrace,
                     settings.proximityLockRequiresAll, settings.proximityLockUseDistance)
        defer {
            settings.proximityLockEnabled = saved.0
            settings.proximityLockDevices = saved.1
            settings.proximityLockGrace = saved.2
            settings.proximityLockRequiresAll = saved.3
            settings.proximityLockUseDistance = saved.4
        }
        settings.proximityLockGrace = 10
        settings.proximityLockRequiresAll = false
        settings.proximityLockUseDistance = false
        settings.proximityLockDevices = [phone: "iPhone"]
        settings.proximityLockEnabled = true
        body(settings)
    }

    func testNoLockWhileTheScreenIsAlreadyLocked() {
        withLockSettings { settings in
            var locks = 0
            var usable = false
            let proximity = ProximityLock(settings: settings, reader: { [] }, lockAction: { locks += 1 }, canLockNow: { usable })
            proximity.handle([entry(phone, rssi: -55)], now: start)
            proximity.handle([], now: start.addingTimeInterval(30))
            XCTAssertEqual(locks, 0, "already locked or display off: nothing to do")
            usable = true
            proximity.handle([], now: start.addingTimeInterval(40))
            XCTAssertEqual(locks, 1, "unlocked while the phone is still away: locks")
        }
    }

    func testLocksAgainAfterThePhoneComesBackAndLeaves() {
        withLockSettings { settings in
            var locks = 0
            let proximity = ProximityLock(settings: settings, reader: { [] }, lockAction: { locks += 1 }, canLockNow: { true })
            proximity.handle([entry(phone, rssi: -55)], now: start)
            proximity.handle([], now: start.addingTimeInterval(15))
            XCTAssertEqual(locks, 1)
            proximity.handle([], now: start.addingTimeInterval(60))
            XCTAssertEqual(locks, 1, "once per departure, not in a loop")
            proximity.handle([entry(phone, rssi: -50)], now: start.addingTimeInterval(70)) // back at the desk
            proximity.handle([], now: start.addingTimeInterval(75))
            XCTAssertEqual(locks, 1, "within the grace period")
            proximity.handle([], now: start.addingTimeInterval(85))
            XCTAssertEqual(locks, 2)
        }
    }
}
