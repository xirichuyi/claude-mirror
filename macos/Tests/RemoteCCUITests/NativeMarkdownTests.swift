#if canImport(AppKit)
import AppKit
import XCTest
@testable import RemoteCC

@MainActor final class NativeMarkdownTests: XCTestCase {
    func testFencesRemainCodeWhileStreamingAndPreserveCopyPayload() {
        let source = "前言\n\n```swift\nlet name = \"中文🌿\"\nprint(name)\n"
        let before = NativeMarkdown.blocks(source)
        let after = NativeMarkdown.blocks(source + "```\n\n完成")
        XCTAssertEqual(before.map(\.kind), [.prose, .code])
        XCTAssertEqual(after.map(\.kind), [.prose, .code, .prose])
        XCTAssertEqual(before[1].language, "swift")
        XCTAssertEqual(before[1].content.string, "let name = \"中文🌿\"\nprint(name)\n")
        XCTAssertEqual(before[1].content, after[1].content)
        XCTAssertEqual(before[1].id, after[1].id)
    }

    func testNestedListsTaskListsAndInlineStyles() {
        let source = "3. **外层**\n   - 内层 *强调*\n     - 更深\n\n- [x] 完成\n- [ ] 待办\n\n~~删除~~ 与 `短代码`"
        let document = NativeMarkdown.document(source)
        XCTAssertTrue(document.string.contains("3. 外层"))
        XCTAssertTrue(document.string.contains("☑ 完成"))
        XCTAssertTrue(document.string.contains("☐ 待办"))
        let inner = (document.string as NSString).range(of: "内层")
        let deeper = (document.string as NSString).range(of: "更深")
        let innerStyle = document.attribute(.paragraphStyle, at: inner.location, effectiveRange: nil) as? NSParagraphStyle
        let deeperStyle = document.attribute(.paragraphStyle, at: deeper.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(deeperStyle?.headIndent ?? 0, innerStyle?.headIndent ?? 0)
        let strike = (document.string as NSString).range(of: "删除")
        XCTAssertNotNil(document.attribute(.strikethroughStyle, at: strike.location, effectiveRange: nil))
    }

    func testTableHasItsOwnWidthAndNativeSelectableCells() {
        let blocks = NativeMarkdown.blocks("| 名称 | 数值 | 说明 |\n| :--- | ---: | :---: |\n| A | 42 | **中文** |")
        XCTAssertEqual(blocks.count, 1); XCTAssertEqual(blocks.first?.kind, .table)
        XCTAssertGreaterThan(blocks[0].width, 320)
        let content = blocks[0].content
        let range = (content.string as NSString).range(of: "42")
        let style = content.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .right)
        XCTAssertEqual(style?.textBlocks.count, 1)
        XCTAssertTrue(content.string.contains("中文"))
    }

    func testRemoteImageAndFileLinksAreRoutedWithoutFetchingHTML() {
        let document = NativeMarkdown.document("![图片](/tmp/图.png) [网页](https://example.com) [危险](javascript:alert)\n\n<script>alert(1)</script>")
        var links: [URL] = []
        document.enumerateAttribute(.link, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertTrue(links.contains { $0.scheme == "rcc-file" })
        XCTAssertTrue(links.contains { $0.scheme == "https" })
        XCTAssertFalse(links.contains { $0.scheme == "javascript" })
        XCTAssertTrue(document.string.contains("<script>"))
    }

    func testEveryStreamingPrefixCanRender() {
        let source = "## 标题\n\n**粗体**与[文件](/tmp/报告.txt)\n\n| A | B |\n|---|---|\n| 中 | 文 |\n\n```js\nconsole.log('🌿')\n```"
        for count in 1...source.count {
            let blocks = NativeMarkdown.blocks(String(source.prefix(count)))
            XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
        }
    }
}
#endif
