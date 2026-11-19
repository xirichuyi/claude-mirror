import XCTest
@testable import RemoteCCCore

@MainActor
final class ReplyTextChangeTests: XCTestCase {
    private var base: ChatSession = {
        var session = ChatSession(config: ConnectionConfig(host: "example", directory: "/project"))
        session.messages = [ChatMessage(id: "question", role: "user", text: "hi"), ChatMessage(id: "reply", role: "assistant", blocks: [])]
        session.status = "working"
        session.remoteOwner = try? JSONDecoder().decode(RemoteOwner.self, from: Data(#"{"id":"task","version":6}"#.utf8))
        return session
    }()
    private let tool = Block(type: "tool", id: "t1", name: "Edit", input: ["file_path": "/project/a.swift"], status: "running")

    private func reply(_ blocks: [Block]) -> ChatSession {
        var session = base
        session.messages[1].blocks = blocks
        return session
    }

    func testAddedTextAndThinkingAreReplyTextOnly() {
        let old = reply([Block(type: "thinking", text: "a"), tool, Block(type: "text", text: "Hello")])
        var new = reply([Block(type: "thinking", text: "a b"), tool, Block(type: "text", text: "Hello wor"), Block(type: "text", text: "ld")])
        new.remoteOwner?.version = 7
        XCTAssertTrue(ChatEngine.onlyReplyTextChanged(from: old, to: new, message: 1))
        XCTAssertTrue(ChatEngine.onlyReplyTextChanged(from: reply([]), to: reply([Block(type: "text", text: "H")]), message: 1))
    }

    func testToolStatusAndPermissionChangesReachEveryObserver() {
        let old = reply([Block(type: "text", text: "Hello"), tool])
        var finished = tool; finished.status = "done"
        XCTAssertFalse(ChatEngine.onlyReplyTextChanged(from: old, to: reply([Block(type: "text", text: "Hello"), finished]), message: 1))
        XCTAssertFalse(ChatEngine.onlyReplyTextChanged(from: reply([Block(type: "text", text: "Hello")]), to: old, message: 1))
        var idle = old; idle.status = "idle"
        XCTAssertFalse(ChatEngine.onlyReplyTextChanged(from: old, to: idle, message: 1))
        var failed = old; failed.messages[1].error = "连接中断"
        XCTAssertFalse(ChatEngine.onlyReplyTextChanged(from: old, to: failed, message: 1))
        var asking = old
        asking.permissions = (try? JSONDecoder().decode([PermissionRequest].self, from: Data(#"[{"id":"p1"}]"#.utf8))) ?? []
        XCTAssertEqual(asking.permissions.count, 1)
        XCTAssertFalse(ChatEngine.onlyReplyTextChanged(from: old, to: asking, message: 1))
    }
}
