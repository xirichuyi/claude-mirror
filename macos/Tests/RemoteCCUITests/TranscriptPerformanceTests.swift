import AppKit
import SwiftUI
import Combine
import XCTest
import RemoteCCCore
@testable import RemoteCC

@MainActor
final class TranscriptPerformanceTests: XCTestCase {
    private struct Screen: View {
        @ObservedObject var state: TranscriptState
        let model: AppModel
        var page = TranscriptWindow()
        var body: some View {
            if let session = state.session {
                MessagesList(session: session, model: model, historyError: nil, refreshing: false, initialWindow: page)
                    .id(page.endID ?? "latest")
                    .environmentObject(model)
            }
        }
    }

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }

    func testNativeHistoryPagingKeepsViewCountBounded() async throws {
        _ = NSApplication.shared
        var session = ChatSession(config: ConnectionConfig(host: "isolated-fixture"))
        session.messages = (0..<3000).map { ChatMessage(id: "history-\($0)", role: "assistant",
            blocks: [Block(type: "text", text: "历史消息 \($0)\n\n**正文** `code`")]) }
        let model = AppModel(previewSession: session)
        let host = NSHostingView(rootView: Screen(state: model.transcript, model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        var page = TranscriptWindow(), maxViews = 0, pages = 0
        repeat {
            host.rootView = Screen(state: model.transcript, model: model, page: page)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            let views = textViews(host)
            maxViews = max(maxViews, views.count)
            XCTAssertLessThanOrEqual(views.count, 30)
            let range = page.range(in: session.messages)
            XCTAssertTrue(views.contains { $0.string.contains("历史消息 \(range.lowerBound)\n") })
            pages += 1
            if range.lowerBound == 0 { break }
            page.earlier(in: session.messages)
        } while true
        print("NATIVE_HISTORY pages=\(pages) max_text_views=\(maxViews)")
    }

    func testSustainedStreamingAndThreeThousandHistoryMessages() async throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPT_STRESS"] == "1" else {
            throw XCTSkip("Opt-in two-minute native rendering stress test")
        }
        _ = NSApplication.shared
        var session = ChatSession(config: ConnectionConfig(host: "isolated-fixture"))
        session.messages = (0..<3000).map { index in
            ChatMessage(id: "history-\(index)", role: "assistant", blocks: [Block(type: "text", text: "## 历史 \(index)\n\n" + String(repeating: "正文 **粗体** 与 `code`，用于检查布局。\n\n", count: 8))])
        }
        session.status = "working"
        session.messages.append(ChatMessage(id: "stream", role: "assistant", blocks: [Block(type: "text", text: "开始\n\n")]))
        let model = AppModel(previewSession: session)
        var globalRefreshes = 0
        let subscription = model.objectWillChange.sink { globalRefreshes += 1 }
        defer { subscription.cancel() }
        let host = NSHostingView(rootView: Screen(state: model.transcript, model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        var durations: [Double] = []
        let start = Date()
        var updates = 0
        while Date().timeIntervalSince(start) < 120 {
            let tick = Date()
            session.messages[3000].blocks![0].text! += "持续输出 \(updates)：**渲染** 与 `代码`。\n\n"
            model.transcript.update(session)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            durations.append(Date().timeIntervalSince(tick))
            updates += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(globalRefreshes, 0, "Streaming must not publish the entire app model")
        XCTAssertGreaterThan(updates, 1000)
        durations.sort()
        print("STREAM_STRESS seconds=\(Date().timeIntervalSince(start)) updates=\(updates) p95_ms=\(durations[Int(Double(durations.count) * 0.95)] * 1000) max_ms=\(durations.last! * 1000) global_refreshes=\(globalRefreshes)")
        var page = TranscriptWindow(), pages = 0
        let historyStart = Date()
        repeat {
            page.earlier(in: session.messages)
            host.rootView = Screen(state: model.transcript, model: model, page: page)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertLessThanOrEqual(page.range(in: session.messages).count, 30)
            pages += 1
        } while page.range(in: session.messages).lowerBound > 0
        print("HISTORY_STRESS messages=3001 pages=\(pages) seconds=\(Date().timeIntervalSince(historyStart))")
        XCTAssertLessThan(durations[Int(Double(durations.count) * 0.95)], 0.25)
    }
}
