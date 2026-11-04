import XCTest
import RemoteCCCore
@testable import RemoteCC

@MainActor
final class AsyncStateTests: XCTestCase {
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Async state did not settle")
    }

    func testLeavingToolsPageDiscardsLateMutationResult() async {
        let store = SessionToolsStore()
        var reply: CheckedContinuation<(content: JSON?, runtime: JSON?, message: String), Error>?
        store.perform { try await withCheckedThrowingContinuation { reply = $0 } }
        await eventually { reply != nil }
        store.invalidate()
        await store.load(section: .plugins) { _ in ["plugins": ["new-plugin"]] }
        reply?.resume(returning: (["old-task"], nil, "old message"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.content?["plugins"]?.array?.first?.string, "new-plugin")
        XCTAssertNil(store.message)
        XCTAssertFalse(store.busy)
    }

    func testOldLoadCannotClearNewLoadingState() async {
        let store = SessionToolsStore()
        var oldReply: CheckedContinuation<JSON, Error>?
        var newReply: CheckedContinuation<JSON, Error>?
        let old = Task { await store.load(section: .tasks) { _ in try await withCheckedThrowingContinuation { oldReply = $0 } } }
        await eventually { oldReply != nil }
        let new = Task { await store.load(section: .commands) { _ in try await withCheckedThrowingContinuation { newReply = $0 } } }
        await eventually { newReply != nil }
        oldReply?.resume(returning: ["old"])
        await old.value
        XCTAssertTrue(store.busy)
        newReply?.resume(returning: ["new"])
        await new.value
        XCTAssertEqual(store.content?.array?.first?.string, "new")
        XCTAssertFalse(store.busy)
    }

    func testAccountSwitchDiscardsPreviousMachineResponse() async {
        let store = AccountStore()
        var oldReply: CheckedContinuation<JSON, Error>?
        let old = Task { await store.observe(source: "old", loader: { try await withCheckedThrowingContinuation { oldReply = $0 } }) }
        await eventually { oldReply != nil }
        let new = Task { await store.observe(source: "new", loader: { ["account": ["email": "new"], "quota": ["available": true]] }) }
        await eventually { store.status?["account"]?["email"]?.string == "new" }
        oldReply?.resume(returning: ["account": ["email": "old"]])
        old.cancel(); await old.value
        XCTAssertEqual(store.status?["account"]?["email"]?.string, "new")
        new.cancel(); await new.value
    }

    func testAccountRefreshSharesPendingRequest() async {
        let store = AccountStore()
        var reply: CheckedContinuation<JSON, Error>?
        var calls = 0
        let observation = Task { await store.observe(source: "machine", loader: {
            calls += 1
            return try await withCheckedThrowingContinuation { reply = $0 }
        }) }
        await eventually { reply != nil }
        let refresh = Task { await store.refresh() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        reply?.resume(returning: ["quota": ["available": true]])
        await refresh.value
        observation.cancel(); await observation.value
        XCTAssertEqual(store.status?["quota"]?["available"], .bool(true))
    }
}
