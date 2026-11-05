import XCTest
@testable import RemoteCCCore

final class CachePreferenceTests: XCTestCase {
    @MainActor
    func testCachePreferencePreservesResumeAndCanReturnToRemoteDefault() async throws {
        let environment = try AgentEnvironment()
        defer { environment.cleanup() }
        let store = try ChatStore(directory: environment.home.appendingPathComponent("cache-store"))
        var session = ChatSession(config: environment.config)
        session.remoteSessionId = "original-session"
        session.capabilities = Capabilities()
        session.capabilities?.version = "2.1.312"
        store.save([session]); store.flush()
        let engine = try ChatEngine(store: store, agents: environment.agents, files: environment.files)
        var preferences = Preferences()
        preferences.promptCacheTtl = "1h"
        try await engine.configure(session.id, preferences)
        XCTAssertEqual(engine.session(session.id)?.preferences?.promptCacheTtl, "1h")
        XCTAssertEqual(engine.session(session.id)?.remoteSessionId, "original-session")
        let encoded = try JSONEncoder().encode(engine.session(session.id)?.preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: encoded).promptCacheTtl, "1h")
        preferences.promptCacheTtl = "invalid"
        do { try await engine.configure(session.id, preferences); XCTFail("Invalid TTL accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("缓存时长")) }
        preferences.promptCacheTtl = ""
        try await engine.configure(session.id, preferences)
        XCTAssertEqual(engine.session(session.id)?.preferences?.promptCacheTtl, "")
    }
}
