import XCTest
@testable import MenuStats

final class MenubarFitTests: XCTestCase {
    /// 4 modules of 100 pt with labels, 90 pt without; 10 pt between them.
    private func width(_ step: MenubarFit.Step) -> CGFloat {
        CGFloat(step.moduleCount) * (step.labels ? 100 : 90) + CGFloat(max(step.moduleCount - 1, 0)) * 10
    }

    func testLadderGoesLabelsFirstThenOneModuleAtATime() {
        let ladder = MenubarFit.ladder(count: 4, labelsConfigured: true, width: width)
        XCTAssertEqual(ladder.map(\.step), [
            .init(moduleCount: 4, labels: true), .init(moduleCount: 4, labels: false), .init(moduleCount: 3, labels: false),
            .init(moduleCount: 2, labels: false), .init(moduleCount: 1, labels: false),
        ])
        XCTAssertEqual(ladder.map(\.width), [430, 390, 290, 190, 90])
    }

    func testLabelsStayWhenDroppingThemSavesNoRoom() {
        // Without labels this style is wider: the labels stay and modules go one at a time.
        let ladder = MenubarFit.ladder(count: 3, labelsConfigured: true) { step in
            CGFloat(step.moduleCount) * (step.labels ? 100 : 110)
        }
        XCTAssertEqual(ladder.map(\.step), [.init(moduleCount: 3, labels: true), .init(moduleCount: 2, labels: true),
                                            .init(moduleCount: 1, labels: true)])
        XCTAssertTrue(zip(ladder, ladder.dropFirst()).allSatisfy { $0.width > $1.width }, "every step is narrower")
    }

    func testNoLabelsConfigured() {
        let ladder = MenubarFit.ladder(count: 2, labelsConfigured: false, width: width)
        XCTAssertEqual(ladder.map(\.step), [.init(moduleCount: 2, labels: false), .init(moduleCount: 1, labels: false)])
    }

    func testChoosesTheWidestStepThatFits() {
        let ladder = MenubarFit.ladder(count: 4, labelsConfigured: true, width: width)
        XCTAssertEqual(MenubarFit.choose(ladder, room: 500, current: 0), 0)
        XCTAssertEqual(MenubarFit.choose(ladder, room: 400, current: 0), 1)
        XCTAssertEqual(MenubarFit.choose(ladder, room: 300, current: 0), 2, "jumps straight to the step that fits")
        XCTAssertEqual(MenubarFit.choose(ladder, room: 50, current: 0), 4, "never less than one module")
    }

    func testGrowsBackOnlyWithMargin() {
        let ladder = MenubarFit.ladder(count: 4, labelsConfigured: true, width: width)
        XCTAssertEqual(MenubarFit.choose(ladder, room: 395, current: 2), 2, "390 needs 16 pt more to come back")
        XCTAssertEqual(MenubarFit.choose(ladder, room: 410, current: 2), 1)
        XCTAssertEqual(MenubarFit.choose(ladder, room: 1000, current: 3), 0)
    }

    func testRoomIsMeasuredOnlyNextToANotch() {
        XCTAssertEqual(MenubarFit.room(rightEdge: 1360, notchRightEdge: 860), 490)
        XCTAssertNil(MenubarFit.room(rightEdge: 1360, notchRightEdge: nil))
    }
}

final class AIActivityTests: XCTestCase {
    func testDescribe() {
        XCTAssertEqual(AwakeController.describe(["Claude Code"]), "Claude Code al lavoro")
        XCTAssertEqual(AwakeController.describe(["Claude Code", "Codex"]), "Claude Code e Codex al lavoro")
        XCTAssertEqual(AwakeController.describe(["Claude Code", "Claude Code"]), "2 sessioni di Claude Code al lavoro")
    }

    func testRecentTranscriptMeansWorking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("progetto")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fresh = project.appendingPathComponent("sessione.jsonl"), old = project.appendingPathComponent("vecchia.jsonl")
        try Data("{}".utf8).write(to: fresh)
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let monitor = AIActivityMonitor(sources: [.init(tool: "Prova", root: root, depth: 2, extensions: ["jsonl"])], hookDirectory: nil)
        XCTAssertEqual(monitor.activeTranscripts(), ["Prova"], "only the file written in the last 45 s counts")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: fresh.path)
        XCTAssertEqual(monitor.activeTranscripts(), [])
    }

    func testWorkingCountsHookFiles() throws {
        let hooks = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: hooks) }
        try Data().write(to: hooks.appendingPathComponent("strumento"))
        let monitor = AIActivityMonitor(sources: [], hookDirectory: hooks)
        XCTAssertEqual(monitor.sample(hookStaleMinutes: 30).sessions, ["IA"])
    }
}
