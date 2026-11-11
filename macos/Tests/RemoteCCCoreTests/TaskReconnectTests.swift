import XCTest
@testable import RemoteCCCore

@MainActor
final class TaskReconnectTests: XCTestCase {
    func testApplicationRestartReattachesOwnerBeforeReportingConnected() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let store = try ChatStore(directory: env.home.appendingPathComponent("restart-store"))
        let original = try ChatEngine(store: store, agents: env.agents, files: env.files)
        original.updateConnection(env.config, ConnectionState(status: .connected))
        let id = try original.create(env.config).id
        try original.send(id, text: "restart check")
        try await eventually { original.session(id)?.status == "permission" }
        let owner = try XCTUnwrap(original.session(id)?.remoteOwner?.id)
        let messageIDs = original.session(id)?.messages.map(\.id)
        XCTAssertEqual(original.taskConnection(id), .connected)
        original.shutdown()

        let reopened = try ChatEngine(store: store, agents: env.agents, files: env.files)
        XCTAssertEqual(reopened.taskConnection(id), .offline)
        reopened.updateConnection(env.config, ConnectionState(status: .connected))
        XCTAssertEqual(reopened.taskConnection(id), .restoring)
        await reopened.restore(env.config)
        try await eventually { reopened.taskConnection(id) == .connected }
        XCTAssertEqual(reopened.session(id)?.remoteOwner?.id, owner)
        XCTAssertEqual(reopened.session(id)?.messages.map(\.id), messageIDs)
        XCTAssertEqual(reopened.session(id)?.status, "permission")
        try await reopened.respond(id, permission: "p1", answer: ["allow": true])
        try await eventually { reopened.session(id)?.status == "idle" }
        reopened.shutdown()

        // An idle owner may still own background tools. Restore it too, not just busy turns.
        let idleReopened = try ChatEngine(store: store, agents: env.agents, files: env.files)
        idleReopened.updateConnection(env.config, ConnectionState(status: .connected))
        XCTAssertEqual(idleReopened.taskConnection(id), .restoring)
        await idleReopened.restore(env.config)
        try await eventually { idleReopened.taskConnection(id) == .connected }
        XCTAssertEqual(idleReopened.session(id)?.remoteOwner?.id, owner)
        XCTAssertEqual(idleReopened.session(id)?.messages.map(\.id), messageIDs)
        let workers = try FileManager.default.contentsOfDirectory(atPath: env.home.appendingPathComponent(".local/state/remotecc/tasks").path)
        XCTAssertEqual(workers.count, 1)
        try await idleReopened.remove(id)
        idleReopened.shutdown()
    }

    func testIdleReplyStillReportsRunningBackgroundTasks() {
        var session = ChatSession(config: ConnectionConfig(host: "test", directory: "/tmp"))
        session.status = "idle"
        session.tasks = [["id": "ci", "status": "running"], ["id": "done", "status": "completed"],
                         ["id": "ambient", "status": "running", "ambient": true]]
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.runningBackgroundTaskCount, 1)
    }
}
