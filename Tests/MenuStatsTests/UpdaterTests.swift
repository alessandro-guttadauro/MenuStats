import XCTest
@testable import MenuStats

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.3.0", than: "1.2.0"))
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.99.99"))
        XCTAssertTrue(Updater.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(Updater.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.1.9", than: "1.2.0"))
    }

    private func release(_ fields: [String: Any]) -> Data {
        var json: [String: Any] = [
            "tag_name": "v1.4.0", "draft": false, "prerelease": false, "body": "## Novità\n- Qualcosa",
            "html_url": "https://github.com/thomas-addamo/MenuStats/releases/tag/v1.4.0",
            "published_at": "2026-10-19T13:20:00Z",
            "assets": [["name": "MenuStats-1.4.0.zip", "size": 1234,
                        "browser_download_url": "https://github.com/thomas-addamo/MenuStats/releases/download/v1.4.0/MenuStats-1.4.0.zip",
                        "digest": "sha256:abc"]],
        ]
        json.merge(fields) { $1 }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParsesGitHubRelease() throws {
        let parsed = try XCTUnwrap(Updater.parse(release([:])))
        XCTAssertEqual(parsed.version, "1.4.0")
        XCTAssertEqual(parsed.digest, "sha256:abc")
        XCTAssertEqual(parsed.size, 1234)
        XCTAssertEqual(parsed.asset.lastPathComponent, "MenuStats-1.4.0.zip")
        XCTAssertNotNil(parsed.published)
    }

    func testIgnoresDraftsPrereleasesAndReleasesWithoutZip() {
        XCTAssertNil(Updater.parse(release(["draft": true])))
        XCTAssertNil(Updater.parse(release(["prerelease": true])))
        XCTAssertNil(Updater.parse(release(["assets": [["name": "notes.txt", "browser_download_url": "https://example.com/x"]]])))
        XCTAssertNil(Updater.parse(Data("{}".utf8)))
    }

    func testRejectsArchiveWithWrongDigest() throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).zip")
        try Data("not the published archive".utf8).write(to: archive)
        let parsed = try XCTUnwrap(Updater.parse(release([:])))
        guard case .failure(let failure) = Updater.prepare(archive: archive, release: parsed) else {
            return XCTFail("a tampered archive must be rejected")
        }
        XCTAssertTrue(failure.message.contains("non corrisponde"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path), "the download is removed")
    }

    func testRejectsArchiveWithoutTheApp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let archive = folder.appendingPathExtension("zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        var parsed = try XCTUnwrap(Updater.parse(release([:])))
        parsed.digest = nil
        guard case .failure(let failure) = Updater.prepare(archive: archive, release: parsed) else {
            return XCTFail("an archive without MenuStats.app must be rejected")
        }
        XCTAssertTrue(failure.message.contains("MenuStats.app"))
    }
}
