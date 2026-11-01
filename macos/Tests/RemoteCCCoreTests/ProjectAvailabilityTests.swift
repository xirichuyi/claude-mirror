import XCTest
@testable import RemoteCCCore

final class ProjectAvailabilityTests: XCTestCase {
    @MainActor
    func testDeletedProjectKeepsHistoryAndCanBecomeAvailableAgain() async throws {
        let environment = try AgentEnvironment()
        defer { environment.cleanup() }
        let project = environment.home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var config = environment.config
        config.directory = project.path
        let engine = try ChatEngine(store: ChatStore(directory: environment.home.appendingPathComponent("store")), agents: environment.agents, files: environment.files)
        let session = try engine.create(config)
        try await engine.refreshProjects(config)
        XCTAssertFalse(engine.projectMissing(config))
        try FileManager.default.removeItem(at: project)
        try await engine.refreshProjects(config)
        XCTAssertTrue(engine.projectMissing(config))
        XCTAssertNotNil(engine.session(session.id), "Directory deletion must not delete the chat")
        XCTAssertThrowsError(try engine.submit(session.id, text: "must not start"))
        var other = config; other.host = "other-server"
        XCTAssertFalse(engine.projectMissing(other), "Availability is isolated per machine")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await engine.requireProject(config)
        XCTAssertFalse(engine.projectMissing(config))
    }
}
