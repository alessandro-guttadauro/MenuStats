import XCTest
@testable import MenuStats

final class AwakeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("menustats-awake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Runs one hook command like Claude Code does: through `sh`, with the event JSON on stdin, in a private HOME.
    private func run(hook event: String, sessionID: String, home: URL) throws {
        let data = Data(AwakeController.claudeCodeHooksJSON().utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        let inner = try XCTUnwrap(hooks[event]?.first?["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(inner.first?["command"] as? String)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["session_id": sessionID]))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func signals(in home: URL) -> [String] {
        let folder = home.appendingPathComponent(".menustats/ai")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testClaudeCodeHooksCoverStartAndEnd() throws {
        let data = Data(AwakeController.claudeCodeHooksJSON().utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"])
    }

    func testHooksCreateOneSignalPerSessionAndRemoveIt() throws {
        let home = try temporaryDirectory()
        try run(hook: "UserPromptSubmit", sessionID: "aaa", home: home)
        try run(hook: "UserPromptSubmit", sessionID: "bbb", home: home)
        try run(hook: "PostToolUse", sessionID: "aaa", home: home) // refreshes, never duplicates
        XCTAssertEqual(signals(in: home), ["claude-aaa", "claude-bbb"])

        try run(hook: "Stop", sessionID: "aaa", home: home)
        XCTAssertEqual(signals(in: home), ["claude-bbb"])
        try run(hook: "SessionEnd", sessionID: "bbb", home: home)
        XCTAssertEqual(signals(in: home), [])
    }

    func testHooksNeverLeaveTheSignalFolder() throws {
        let home = try temporaryDirectory()
        try run(hook: "UserPromptSubmit", sessionID: "../../escape $(touch pwned)", home: home)
        XCTAssertEqual(signals(in: home), ["claude-escapetouchpwned"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testWorkingCountIgnoresStaleSignals() throws {
        let folder = try temporaryDirectory()
        let now = Date()
        FileManager.default.createFile(atPath: folder.appendingPathComponent("fresh").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("old").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".hidden").path, contents: nil)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)],
                                              ofItemAtPath: folder.appendingPathComponent("old").path)

        XCTAssertEqual(AwakeController.aiWorkingCount(staleAfter: 30, now: now, in: folder), 1)
        XCTAssertEqual(AwakeController.aiWorkingCount(staleAfter: 120, now: now, in: folder), 2)
        XCTAssertEqual(AwakeController.aiWorkingCount(staleAfter: 30, now: now, in: folder.appendingPathComponent("missing")), 0)
    }

    func testRemainingTime() {
        let now = Date()
        XCTAssertNil(AwakeState(isActive: true).remaining(at: now))
        XCTAssertEqual(AwakeState(isActive: true, endDate: now.addingTimeInterval(90)).remaining(at: now), 90)
        XCTAssertEqual(AwakeState(isActive: true, endDate: now.addingTimeInterval(-5)).remaining(at: now), 0)
        XCTAssertEqual(Format.clockCompact(61), "0:02")
        XCTAssertEqual(Format.clock(3725), "1:02:05")
    }

    func testTimedSessionStartsAndStops() throws {
        let awake = AwakeController(settings: .shared)
        awake.start(minutes: 60)
        XCTAssertTrue(awake.state.isActive)
        XCTAssertEqual(try XCTUnwrap(awake.state.remaining()), 3600, accuracy: 2)
        awake.stop()
        XCTAssertFalse(awake.state.isActive)
        XCTAssertNil(awake.state.endDate)
    }

    func testDownloadSessionEndsWhenTheFileStopsGrowing() throws {
        let file = try temporaryDirectory().appendingPathComponent("movie.part")
        FileManager.default.createFile(atPath: file.path, contents: Data(count: 100))
        let awake = AwakeController(settings: .shared)
        awake.start(watching: file, timeout: 2)
        XCTAssertEqual(awake.state.kind, .download(name: "movie.part", progress: nil))

        let deadline = Date().addingTimeInterval(6)
        while awake.state.isActive, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(awake.state.isActive)
        XCTAssertEqual(awake.lastEndReason, "Download terminato: movie.part")
    }

    func testDownloadSessionEndsWhenTheFileDisappears() throws {
        let file = try temporaryDirectory().appendingPathComponent("gone.part")
        FileManager.default.createFile(atPath: file.path, contents: Data(count: 10))
        let awake = AwakeController(settings: .shared)
        awake.start(watching: file, timeout: 600)
        try FileManager.default.removeItem(at: file)

        let deadline = Date().addingTimeInterval(4)
        while awake.state.isActive, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(awake.state.isActive)
        XCTAssertEqual(awake.lastEndReason, "File non più presente")
    }
}
