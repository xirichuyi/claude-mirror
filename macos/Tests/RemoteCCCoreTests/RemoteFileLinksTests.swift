import XCTest
@testable import RemoteCCCore

final class RemoteFileLinksTests: XCTestCase {
    func testDirectoryLinksWithSpacesUnicodeAndRoot() {
        XCTAssertEqual(RemoteFileLinks.reference(URL(string: "docs")!)?.path, "docs")
        XCTAssertNil(RemoteFileLinks.reference(URL(string: "#section")!))
        for path in ["/opt/claude- mirror", "/root/图片/", "/", "~/Documents/", "./docs/", "docs/"] {
            XCTAssertEqual(remotePathReference(path)?.path, path)
            let markdown = RemoteFileLinks.markdown("`" + path + "`")
            XCTAssertTrue(markdown.contains("rcc-file:"))
        }
        XCTAssertEqual(RemoteFileLinks.reference(URL(string: "file:///opt/claude-%20mirror/")!)?.path, "/opt/claude- mirror")
    }

    func testInlineImagePathsAndLineNumbersBecomeLinks() {
        let text = "图片：`/root/claude-mirror-icons/round1-abc.png`。代码 `src/app.swift:12`"
        let result = RemoteFileLinks.markdown(text)
        XCTAssertTrue(result.contains("[`/root/claude-mirror-icons/round1-abc.png`](rcc-file:/root/claude-mirror-icons/round1-abc.png)"))
        XCTAssertTrue(result.contains("(rcc-file:src/app.swift%3A12)"))
        XCTAssertEqual(RemoteFileLinks.reference(URL(string: "rcc-file:src/app.swift%3A12")!)?.line, 12)
    }

    func testExamplesCommandsAndExistingLinksRemainUnchanged() {
        for text in ["```sh\n`/etc/hosts`\n```", "~~~\n`/root/image.png`\n~~~", "    `/etc/hosts`", "`npm install`", "[`/etc/hosts`](https://example.com)", "![image](/root/image.png)", "[`/etc/hosts`][ref]"] {
            XCTAssertEqual(RemoteFileLinks.markdown(text), text)
        }
    }

    func testUnicodeAndFileURLRoutesToRemotePath() {
        let result = RemoteFileLinks.markdown("`/root/图片.png` 和 `/root/a#b.png`")
        XCTAssertTrue(result.contains("%23"))
        XCTAssertEqual(RemoteFileLinks.reference(URL(string: "file:///root/image.png")!)?.path, "/root/image.png")
        XCTAssertEqual(RemoteFileLinks.reference(URL(string: "rcc-file:/root/%E5%9B%BE%E7%89%87.png")!)?.path, "/root/图片.png")
        XCTAssertNil(RemoteFileLinks.reference(URL(string: "https://example.com/image.png")!))
    }
}
