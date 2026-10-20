import XCTest
@testable import MenuStatsHelper
import MenuStatsShared

/// The lid-closed rules of the root helper, against a fake power switch (the real Mac is never touched).
final class LidControllerTests: XCTestCase {
    private final class FakePower {
        var disabled: Bool? = false
        var refuse = false
        var writes: [Bool] = []
        var lidClosed = false
        var sleeps = 0
        var power: LidController.Power {
            LidController.Power(isSleepDisabled: { self.disabled }, setSleepDisabled: { value in
                self.writes.append(value)
                guard !self.refuse else { return false }
                self.disabled = value
                return true
            }, lidClosedShouldSleep: { self.lidClosed }, sleepNow: { self.sleeps += 1 })
        }
    }

    private var marker: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var failsafe: String?
    private let owner = ObjectIdentifier(NSObject())

    override func setUp() {
        marker = FileManager.default.temporaryDirectory.appendingPathComponent("lid-\(UUID().uuidString)/lid-awake")
        failsafe = nil
    }

    override func tearDown() { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

    private func make(_ fake: FakePower) -> LidController {
        LidController(marker: marker, power: fake.power, failsafe: { [unowned self] in failsafe }, now: { [unowned self] in clock })
    }

    func testAcquireDisablesSleepAndReleaseGivesItBack() {
        let fake = FakePower()
        let lid = make(fake)
        XCTAssertNil(lid.acquire(owner: owner))
        XCTAssertEqual(fake.disabled, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "marker written before the switch")
        lid.release(owner: owner, reason: "test")
        XCTAssertEqual(fake.disabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSleepComesBackOnlyWhenTheLastClientLeaves() {
        let fake = FakePower()
        let lid = make(fake)
        let other = ObjectIdentifier(NSString())
        XCTAssertNil(lid.acquire(owner: owner))
        XCTAssertNil(lid.acquire(owner: other))
        XCTAssertEqual(fake.writes, [true], "switched once")
        lid.release(owner: owner, reason: "test")
        XCTAssertEqual(fake.disabled, true)
        lid.release(owner: other, reason: "test")
        XCTAssertEqual(fake.disabled, false)
    }

    func testLeaseExpiresWhenTheAppStopsRenewing() {
        let fake = FakePower()
        let lid = make(fake)
        XCTAssertNil(lid.acquire(owner: owner))
        clock += 120
        XCTAssertEqual(lid.renew(owner: owner).0, true)
        clock += 120
        lid.check()
        XCTAssertEqual(fake.disabled, true, "renewed 120 s ago: still held")
        clock += HelperConstants.lidLeaseSeconds + 1
        lid.check()
        XCTAssertEqual(fake.disabled, false)
        let (held, reason) = lid.renew(owner: owner)
        XCTAssertFalse(held)
        XCTAssertEqual(reason, "MenuStats non risponde")
    }

    func testFailsafesRefuseAndDrop() {
        let fake = FakePower()
        let lid = make(fake)
        failsafe = "Batteria quasi scarica"
        XCTAssertEqual(lid.acquire(owner: owner), "Batteria quasi scarica")
        XCTAssertEqual(fake.disabled, false)
        failsafe = nil
        XCTAssertNil(lid.acquire(owner: owner))
        failsafe = "Il Mac è troppo caldo"
        lid.check()
        XCTAssertEqual(fake.disabled, false, "dropped while held")
        XCTAssertEqual(lid.holderCount, 0)
    }

    func testRecoverAfterACrashTurnsSleepBackOn() {
        let fake = FakePower()
        XCTAssertNil(make(fake).acquire(owner: owner)) // the helper "dies" holding it
        XCTAssertEqual(fake.disabled, true)
        make(fake).recover() // next start
        XCTAssertEqual(fake.disabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNeverUndoesASwitchSetByTheUser() {
        let fake = FakePower()
        fake.disabled = true // `sudo pmset disablesleep 1` by the user
        let lid = make(fake)
        XCTAssertNil(lid.acquire(owner: owner))
        lid.release(owner: owner, reason: "test")
        XCTAssertEqual(fake.disabled, true)
        XCTAssertEqual(fake.writes, [])
    }

    func testRefusalFromMacOSLeavesNothingBehind() {
        let fake = FakePower()
        fake.refuse = true
        let lid = make(fake)
        XCTAssertEqual(lid.acquire(owner: owner), "macOS ha rifiutato di disattivare lo stop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(lid.holderCount, 0)
    }

    func testLidClosedWhenSleepComesBackSleepsAtOnce() {
        let fake = FakePower()
        let lid = make(fake)
        XCTAssertNil(lid.acquire(owner: owner))
        fake.lidClosed = true // closed during the session: the Mac stayed awake
        lid.release(owner: owner, reason: "fine sessione")
        XCTAssertEqual(fake.disabled, false)
        XCTAssertEqual(fake.sleeps, 1, "the Mac goes to sleep as if the lid had just been closed")
    }

    func testLidOpenWhenSleepComesBackDoesNothingElse() {
        let fake = FakePower()
        let lid = make(fake)
        XCTAssertNil(lid.acquire(owner: owner))
        lid.release(owner: owner, reason: "fine sessione")
        XCTAssertEqual(fake.sleeps, 0)
    }

    func testRestoreDropsEveryone() {
        let fake = FakePower()
        let lid = make(fake)
        XCTAssertNil(lid.acquire(owner: owner))
        lid.restore(reason: "helper terminato")
        XCTAssertEqual(fake.disabled, false)
        XCTAssertEqual(lid.renew(owner: owner).1, "helper terminato")
    }
}
