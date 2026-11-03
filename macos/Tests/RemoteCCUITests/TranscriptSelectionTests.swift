#if canImport(AppKit)
import AppKit
import XCTest
@testable import RemoteCC

final class TranscriptSelectionTests: XCTestCase {
    @MainActor func testMarkdownProducesOneSelectableDocumentWithHeadingsTableAndLinks() {
        _ = NSApplication.shared
        let text = SelectableTranscriptText.render("## 标题\n\n第一段\n\n第二段 [文件](/tmp/test.txt)\n\n| 列 | 值 |\n| --- | --- |\n| A | B |", markdown: true)
        XCTAssertTrue(text.string.contains("标题"))
        XCTAssertTrue(text.string.contains("第一段"))
        XCTAssertTrue(text.string.contains("第二段"))
        XCTAssertTrue(text.string.contains("A"))
        var links = 0
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in if value != nil { links += 1 } }
        XCTAssertEqual(links, 1)
        var tableCells = 0
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { tableCells += 1 }
        }
        XCTAssertGreaterThanOrEqual(tableCells, 4)
        XCTAssertTrue(SelectableTranscriptText.html("| a | b |\n| --- | --- |\n| c | d |").contains("<td>c</td>"))
    }
    @MainActor func testSelectionCopiesAcrossMessageViewsInVisualOrder() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scope = TranscriptSelection()
        let top = TranscriptTextView(frame: NSRect(x: 0, y: 200, width: 450, height: 100))
        let bottom = TranscriptTextView(frame: NSRect(x: 0, y: 20, width: 450, height: 100))
        top.string = "first paragraph\nsecond paragraph"; bottom.string = "next message"
        for view in [bottom, top] { window.contentView!.addSubview(view); scope.register(view); view.selectionScope = scope }
        scope.select(from: top, anchor: 0, to: bottom.convert(NSPoint(x: 440, y: 50), to: nil))
        XCTAssertEqual(scope.selectedText, top.string + "\n\n" + bottom.string)
        scope.select(from: bottom, anchor: (bottom.string as NSString).length, to: top.convert(NSPoint(x: 0, y: 0), to: nil))
        XCTAssertEqual(scope.selectedText, top.string + "\n\n" + bottom.string)
        scope.clear(); XCTAssertEqual(scope.selectedText, "")
    }
}
#endif
