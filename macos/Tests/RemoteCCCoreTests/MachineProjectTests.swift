import XCTest
@testable import RemoteCCCore

final class MachineProjectTests: XCTestCase {
    @MainActor
    func testMachineEditPreservesProjectAndConversationAcrossReload() throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let store = try ChatStore(directory: env.home.appendingPathComponent("store"))
        let engine = try ChatEngine(store: store, agents: env.agents, files: env.files)
        let original = try engine.create(env.config, name: "existing conversation")
        var other = env.config; other.host = "other"
        let unrelated = try engine.create(other)
        var updated = env.config
        updated.host = "user@new-host"
        updated.port = 2222
        updated.authentication = .keyFile
        updated.identityFile = "/tmp/new-key"
        updated.directory = "~"
        try engine.replaceMachine(env.config, with: updated)
        store.flush()
        let reloaded = try ChatEngine(store: store, agents: env.agents, files: env.files)
        let preserved = try XCTUnwrap(reloaded.session(original.id))
        XCTAssertEqual(preserved.config.key, updated.key)
        XCTAssertEqual(preserved.directory, original.directory)
        XCTAssertEqual(preserved.name, original.name)
        XCTAssertEqual(reloaded.session(unrelated.id)?.config.key, other.key)
        XCTAssertEqual(reloaded.sessions.count, 2)
    }

    func testCreateProjectWithSpacesRejectsDuplicateAndTraversal() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let entry = try await env.files.createFolder(env.config, in: env.home.path, name: "我的项目 ' demo")
        XCTAssertTrue(entry.directory)
        let listing = try await env.files.list(env.config, entry.path, hidden: false, force: true)
        XCTAssertEqual(listing.path, entry.path)
        for name in ["我的项目 ' demo", "../escape", ".", "", "bad\nname"] {
            do {
                _ = try await env.files.createFolder(env.config, in: env.home.path, name: name)
                XCTFail("Must reject invalid or existing folder: \(name)")
            } catch { }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }
}
