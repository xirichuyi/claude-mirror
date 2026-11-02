import XCTest
@testable import RemoteCCCore

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.17.0", than: "0.16.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.16.1", than: "0.16"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.16.0", than: "0.16.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.16", than: "0.16.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.15.9", than: "0.16.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.18.0-beta", than: "0.16.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "0.16.0"))
    }

    private func release(_ fields: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "tag_name": "v0.17.0", "draft": false, "prerelease": false, "body": "  更新说明  ",
            "html_url": "https://github.com/xirichuyi/claude-mirror/releases/tag/v0.17.0",
            "assets": [
                ["name": "Claude-Mirror-0.17.0-macOS-x86_64.dmg", "browser_download_url": "https://github.com/xirichuyi/claude-mirror/releases/download/v0.17.0/Claude-Mirror-0.17.0-macOS-x86_64.dmg"],
                ["name": "Claude-Mirror-0.17.0-macOS-arm64.dmg.sha256", "browser_download_url": "https://github.com/xirichuyi/claude-mirror/releases/download/v0.17.0/x.sha256"],
                ["name": "Claude-Mirror-0.17.0-macOS-arm64.dmg", "browser_download_url": "https://github.com/xirichuyi/claude-mirror/releases/download/v0.17.0/Claude-Mirror-0.17.0-macOS-arm64.dmg"]
            ]
        ]
        fields.forEach { object[$0.key] = $0.value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testParsePicksTheDMGForThisArchitecture() throws {
        let update = try XCTUnwrap(UpdateChecker.parse(release([:]), architecture: "arm64"))
        XCTAssertEqual(update.version, "0.17.0")
        XCTAssertEqual(update.notes, "更新说明")
        XCTAssertEqual(update.downloadURL?.lastPathComponent, "Claude-Mirror-0.17.0-macOS-arm64.dmg")
        XCTAssertEqual(update.pageURL.absoluteString, "https://github.com/xirichuyi/claude-mirror/releases/tag/v0.17.0")
        XCTAssertNil(try UpdateChecker.parse(release(["assets": []]), architecture: "arm64")?.downloadURL)
    }

    func testParseRefusesDraftsPrereleasesAndForeignLinks() throws {
        XCTAssertNil(UpdateChecker.parse(try release(["draft": true])))
        XCTAssertNil(UpdateChecker.parse(try release(["prerelease": true])))
        XCTAssertNil(UpdateChecker.parse(try release(["tag_name": "nightly"])))
        XCTAssertNil(UpdateChecker.parse(try release(["html_url": "https://evil.example/claude-mirror"])))
        XCTAssertNil(UpdateChecker.parse(try release(["html_url": "https://github.com/someone-else/claude-mirror/releases/tag/v0.17.0"])))
        let foreignAsset = try release(["assets": [["name": "Claude-Mirror-0.17.0-macOS-arm64.dmg", "browser_download_url": "https://evil.example/x.dmg"]]])
        XCTAssertNil(UpdateChecker.parse(foreignAsset, architecture: "arm64")?.downloadURL)
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
    }
}
