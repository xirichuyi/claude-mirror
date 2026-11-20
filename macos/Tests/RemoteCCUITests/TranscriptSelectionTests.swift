#if canImport(AppKit)
import AppKit
import XCTest
@testable import RemoteCC

final class TranscriptSelectionTests: XCTestCase {
    @MainActor private func normalized(_ value: NSAttributedString) -> NSAttributedString {
        let storage = NSTextStorage(attributedString: value)
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        return storage
    }

    @MainActor func testLongMarkdownKeepsCompletedChunksStableWhileAppending() {
        let source = String(repeating: "完整段落 **强调** 和 `code`。\n\n", count: 600)
        let before = NativeMarkdown.blocks(source)
        let after = NativeMarkdown.blocks(source + "新增的最后一段")
        XCTAssertGreaterThan(before.count, 1)
        XCTAssertTrue(before[0].content.isEqual(to: after[0].content))
        let document = NativeMarkdown.document(source + "新增的最后一段").string
        XCTAssertEqual(document.components(separatedBy: "完整段落").count - 1, 600)
        XCTAssertTrue(document.hasSuffix("新增的最后一段"))
    }

    @MainActor func testStreamingSuffixPreservesTextAndRestylesChangedMarkdown() {
        let initial = NSAttributedString(string: "旧段落 👨‍👩‍👧‍👦\n新增", attributes: [.foregroundColor: NSColor.labelColor])
        let storage = NSTextStorage(attributedString: initial)
        let appended = NSAttributedString(string: initial.string + "内容 😀", attributes: [.foregroundColor: NSColor.labelColor])
        SelectableTranscriptText.replaceChangedSuffix(in: storage, with: appended, previous: initial)
        XCTAssertTrue(storage.isEqual(to: normalized(appended)))
        let restyled = NSMutableAttributedString(attributedString: appended)
        restyled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 3))
        SelectableTranscriptText.replaceChangedSuffix(in: storage, with: restyled, previous: appended)
        XCTAssertTrue(storage.isEqual(to: normalized(restyled)))
        let shortened = NSAttributedString(string: "变短")
        SelectableTranscriptText.replaceChangedSuffix(in: storage, with: shortened, previous: restyled)
        XCTAssertTrue(storage.isEqual(to: normalized(shortened)))
    }

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
    }
    @MainActor func testLongCodePromptsWrapAtNarrowWidthsWithoutLosingText() {
        _ = NSApplication.shared
        let prompt = String(repeating: "young Chinese man, dark urban fantasy, 你好世界 ", count: 12)
        let rendered = SelectableTranscriptText.render("1. **午夜都市** `" + prompt + "`\n\n```text\n" + prompt + "\n```", markdown: true)
        XCTAssertTrue(rendered.string.contains(prompt))
        let storage = NSTextStorage(attributedString: rendered)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let narrow = layout.usedRect(for: container)
        XCTAssertLessThanOrEqual(narrow.maxX, 321)
        XCTAssertEqual(NSMaxRange(layout.glyphRange(for: container)), layout.numberOfGlyphs)
        container.containerSize.width = 720
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(narrow.height, layout.usedRect(for: container).height)
    }

    @MainActor func testSelectionIncludesCodeInsideHorizontalScroller() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let scope = TranscriptSelection()
        let top = TranscriptTextView(frame: NSRect(x: 0, y: 400, width: 450, height: 100))
        let code = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        let bottom = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 100))
        top.string = "正文"; code.string = "let value = 42"; bottom.string = "下一条消息"
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 200, width: 450, height: 100))
        scroller.documentView = code; scroller.hasHorizontalScroller = true
        window.contentView!.addSubview(top); window.contentView!.addSubview(scroller); window.contentView!.addSubview(bottom)
        for view in [top, code, bottom] { scope.register(view); view.selectionScope = scope }
        scope.select(from: top, anchor: 0, to: bottom.convert(NSPoint(x: 440, y: 50), to: nil))
        XCTAssertEqual(scope.selectedText, "正文\n\nlet value = 42\n\n下一条消息")
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
