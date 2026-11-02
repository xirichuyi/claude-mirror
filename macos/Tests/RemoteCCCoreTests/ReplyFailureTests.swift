import XCTest
@testable import RemoteCCCore

final class ReplyFailureTests: XCTestCase {
    func testSafetyMessageKeepsDiagnostics() {
        let raw = "API Error: Opus 5.5's safeguards flagged this session\nDetails: `[cyber]`\nRequest ID: req_123"
        let failure = ReplyFailure(raw)
        XCTAssertTrue(failure.isSafetyBlock)
        XCTAssertEqual(failure.title, "请求被安全机制拦截")
        XCTAssertEqual(failure.raw, raw)
        XCTAssertTrue(failure.duplicates(Block(type: "text", text: "Opus 5.5's safeguards flagged this session\nDetails: [cyber]\nRequest ID: req_123")))
    }

    func testDoesNotHideUsefulContentOrDifferentRequests() {
        let failure = ReplyFailure("API Error: failed\nRequest ID: one")
        XCTAssertFalse(failure.duplicates(Block(type: "text", text: "Some work completed. API Error: failed\nRequest ID: one")))
        XCTAssertFalse(failure.duplicates(Block(type: "text", text: "API Error: failed\nRequest ID: two")))
        XCTAssertFalse(failure.duplicates(Block(type: "tool", text: failure.raw)))
        XCTAssertFalse(failure.isSafetyBlock)
    }

    func testGenericErrorSummaryUsesFirstNonemptyLine() {
        XCTAssertEqual(ReplyFailure("\nConnection closed\nDetails").summary, "Connection closed")
        XCTAssertEqual(ReplyFailure("").summary, "查看详情以了解原因。")
    }
}
