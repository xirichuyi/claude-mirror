import Foundation
import XCTest
import RemoteCCCore
@testable import RemoteCC

final class RecentConversationTests: XCTestCase {
    func testRestoresLastViewedEvenWhenAnotherChatHasNewerMessages() throws {
        let suite = "recent-conversation-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentConversation(defaults: defaults)
        var first = ChatSession(config: ConnectionConfig(host: "first"))
        var second = ChatSession(config: ConnectionConfig(host: "second"))
        first.updatedAt = 1; second.updatedAt = 2
        store.remember(first.id)
        store.remember(nil)
        // Recreate the store to cover an app relaunch, not an in-memory selection.
        XCTAssertEqual(RecentConversation(defaults: defaults).resolve(in: [first, second]), first.id)
        first.archived = true
        XCTAssertEqual(store.resolve(in: [first, second]), second.id)
        XCTAssertEqual(store.resolve(in: [second]), second.id)
        XCTAssertNil(store.resolve(in: []))
    }
}
