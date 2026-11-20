import XCTest
@testable import RemoteCCCore

final class ReplyScrollPolicyTests: XCTestCase {
    func testSmallScrollAndContentClickDoNotShowJump() {
        for distance in [0.0, 24] {
            XCTAssertFalse(ReplyScrollPolicy.showsJump(distance: distance, following: false))
        }
        XCTAssertTrue(ReplyScrollPolicy.showsJump(distance: 25, following: false))
        XCTAssertFalse(ReplyScrollPolicy.showsJump(distance: 250, following: true))
    }

    func testReturningToBottomResumesFollowing() {
        XCTAssertTrue(ReplyScrollPolicy.isNearBottom(48))
        XCTAssertFalse(ReplyScrollPolicy.isNearBottom(49))
    }

    func testHistoricalUsageOutputIsAssistantTextWithOriginalLineBreaks() throws {
        let output = ["Current session: 20%", "Current week: 30%"].joined(separator: String(UnicodeScalar(10)))
        let record: JSON = ["type": "user", "uuid": "usage-output", "message": ["content": [["type": "text", "text": .string("<local-command-stdout>" + output + "</local-command-stdout>")]]]]
        let messages = historyMessages([record])
        XCTAssertEqual(messages.first?.role, "assistant")
        XCTAssertEqual(messages.first?.blocks?.first?.format, "command")
        XCTAssertEqual(messages.first?.blocks?.first?.text, output)
    }
}
