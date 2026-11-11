import XCTest
@testable import RemoteCCCore

final class TranscriptWindowTests: XCTestCase {
    func testThreeThousandMessagesRemainReachableWithoutGrowingPage() {
        let messages = (0..<3000).map { ChatMessage(id: "\($0)", role: "user", text: "message \($0)") }
        var page = TranscriptWindow(), seen = Set<String>()
        repeat {
            let range = page.range(in: messages)
            XCTAssertLessThanOrEqual(range.count, 30)
            seen.formUnion(messages[range].map(\.id))
            if range.lowerBound == 0 { break }
            page.earlier(in: messages)
        } while true
        XCTAssertEqual(seen.count, 3000)
        while page.range(in: messages).upperBound < messages.count { page.later(in: messages) }
        XCTAssertEqual(page.range(in: messages), 2970..<3000)
    }

    func testHistoryPrependAndNewReplyPreserveReadingAnchor() {
        var messages = (0..<100).map { ChatMessage(id: "\($0)", role: "user") }
        var page = TranscriptWindow()
        page.earlier(in: messages)
        let ids = messages[page.range(in: messages)].map(\.id)
        messages.insert(contentsOf: (0..<50).map { ChatMessage(id: "older-\($0)", role: "user") }, at: 0)
        messages.append(ChatMessage(role: "assistant"))
        XCTAssertEqual(messages[page.range(in: messages)].map(\.id), ids)
        page.latest()
        XCTAssertEqual(page.range(in: messages).upperBound, messages.count)
    }

    func testTextDeltasDoNotChangeMetadataButPermissionsAndStatusDo() {
        var session = ChatSession(config: ConnectionConfig(host: "fixture"))
        session.status = "working"
        let metadata = session.transcriptIndependentState
        session.messages = [ChatMessage(role: "assistant", blocks: [Block(type: "text", text: "stream")])]
        XCTAssertEqual(metadata, session.transcriptIndependentState)
        session.status = "permission"
        XCTAssertNotEqual(metadata, session.transcriptIndependentState)
    }
    @MainActor func testEngineRoutesTextOnlyUpdatesWithoutSuppressingTurnEnd() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let store = try ChatStore(directory: env.home.appendingPathComponent("routing-store"))
        var session = ChatSession(config: env.config)
        session.status = "working"
        session.messages = [ChatMessage(id: "reply", role: "assistant", blocks: [])]
        session.remoteOwner = RemoteOwner(id: "fixture", version: 0, messageId: "reply")
        store.save([session]); store.flush()
        let engine = try ChatEngine(store: store, agents: env.agents, files: env.files)
        var initialized = false
        engine.onChange = { initialized = true }
        try await engine.hydrateAsync(session.id)
        initialized = false
        try engine.apply(session.id, state: ["version": 0, "status": "working", "resident": true,
            "message": ["id": "reply", "role": "assistant", "blocks": []]])
        try await eventually { initialized }
        var global = 0, transcript = 0
        engine.onChange = { global += 1 }
        engine.onTranscriptChange = { ids in
            XCTAssertEqual(ids, [session.id]); transcript += 1
        }
        for version in 1...100 {
            let packet: JSON = ["version": .number(Double(version)), "status": "working", "resident": true,
                "message": ["id": "reply", "role": "assistant", "blocks": [["type": "text", "text": .string("delta \(version)")]]]]
            try engine.apply(session.id, state: packet)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(global, 0)
        XCTAssertGreaterThan(transcript, 0)
        try engine.apply(session.id, state: ["version": 101, "status": "idle", "resident": true,
            "message": ["id": "reply", "role": "assistant", "blocks": [["type": "text", "text": "done"]]]])
        try await eventually { global == 1 }
        XCTAssertEqual(global, 1)
        XCTAssertEqual(engine.session(session.id)?.messages.last?.blocks?.last?.text, "done")
        engine.shutdown()
    }

}
