import AppKit
import SwiftUI
import XCTest
import RemoteCCCore
@testable import RemoteCC

@MainActor final class TranscriptViewportTests: XCTestCase {
    private struct Screen: View {
        let model: AppModel
        @ObservedObject var transcript: TranscriptState
        var body: some View {
            if let session = transcript.session {
                MessagesList(session: session, model: model, historyError: nil, refreshing: false)
                    .id(session.id).environmentObject(model)
            }
        }
    }
    private func scroll(in view: NSView) -> NSScrollView? {
        if let value = view as? NSScrollView { return value }
        return view.subviews.lazy.compactMap { self.scroll(in: $0) }.first
    }
    private func settle(_ host: NSView, until predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Viewport did not settle")
    }
    func testSwitchingConversationRestoresExactReadingOffset() async throws {
        _ = NSApplication.shared
        var first = ChatSession(config: ConnectionConfig(host: "viewport-fixture"))
        first.messages = (0..<8).map { index in
            ChatMessage(role: "assistant", blocks: [Block(type: "text", text: "消息 \(index)\n\n" + String(repeating: "正文内容，保持相同的布局和换行。\n\n", count: 12))])
        }
        var second = first
        second.id = "other-conversation"
        let model = AppModel(previewSession: first)
        let remembered = model.transcriptViewport(for: first.id)
        remembered.following = false
        let host = NSHostingView(rootView: Screen(model: model, transcript: model.transcript))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host) { remembered.offset != nil }
        let firstScroll = try XCTUnwrap(scroll(in: host))
        firstScroll.contentView.scroll(to: CGPoint(x: 0, y: 371))
        firstScroll.reflectScrolledClipView(firstScroll.contentView)
        try await settle(host) { abs((remembered.offset?.y ?? 0) - 371) < 1 }
        model.transcript.update(second)
        try await settle(host) { model.transcriptViewport(for: second.id).offset != nil }
        model.transcript.update(first)
        try await settle(host) { abs((scroll(in: host)?.contentView.bounds.origin.y ?? 0) - 371) < 1 }
        XCTAssertFalse(remembered.following)
        XCTAssertEqual(try XCTUnwrap(scroll(in: host)).contentView.bounds.origin.y, 371, accuracy: 1)
    }
}
