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

    func testStopReachesResidentOwnerWithoutLocalRemoteTask() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let engine = try ChatEngine(store: ChatStore(directory: env.home.appendingPathComponent("stop-store")), agents: env.agents, files: env.files)
        engine.updateConnection(env.config, ConnectionState(status: .connected))
        let id = try engine.create(env.config).id
        try engine.send(id, text: "stop recovery fixture")
        try await eventually { engine.session(id)?.status == "permission" }
        try await engine.respond(id, permission: "p1", answer: ["allow": true])
        try await eventually { engine.session(id)?.status == "idle" }
        let session = try XCTUnwrap(engine.session(id))
        let owner = try XCTUnwrap(session.remoteOwner)
        XCTAssertNil(session.remoteTask)
        // The resident SDK can emit more work without a new local send.
        try engine.apply(id, state: ["version": .number(Double(owner.version)), "status": "working", "resident": true,
            "message": try JSON.from(XCTUnwrap(session.messages.last))])
        XCTAssertTrue(engine.session(id)?.isBusy == true)
        XCTAssertNil(engine.session(id)?.remoteTask)
        try await engine.stop(id)
        try await eventually { engine.session(id)?.status == "stopped" }
        try await engine.remove(id)
        engine.shutdown()
    }

    func testAcknowledgedButIgnoredStopClosesOnlyThatOwnerAndClearsStaleBusyState() async throws {
        let worker = standInWorker
            .replacingOccurrences(of: "if(c.kind==='stop'){permissions=[];status='stopped';message.interrupted=true;write();}", with: "if(c.kind==='stop'){}")
            .replacingOccurrences(of: "if(c.kind==='close'){status='idle';write(true);process.exit(0);}", with: "if(c.kind==='close'){status='working';write(true);process.exit(0);}")
        XCTAssertNotEqual(worker, standInWorker)
        let env = try AgentEnvironment(workerSource: worker); defer { env.cleanup() }
        let engine = try ChatEngine(store: ChatStore(directory: env.home.appendingPathComponent("ignored-stop")), agents: env.agents, files: env.files)
        engine.updateConnection(env.config, ConnectionState(status: .connected))
        let id = try engine.create(env.config).id
        let other = try engine.create(env.config).id
        try engine.send(id, text: "ignore stop")
        try engine.send(other, text: "keep running")
        try await eventually { engine.session(id)?.status == "permission" && engine.session(other)?.status == "permission" }
        try await engine.stop(id)
        XCTAssertEqual(engine.session(id)?.status, "stopped")
        XCTAssertNil(engine.session(id)?.remoteOwner)
        XCTAssertTrue(engine.session(id)?.messages.last?.interrupted == true)
        XCTAssertEqual(engine.session(other)?.status, "permission")
        try await engine.stop(other)
        try await engine.remove(id); try await engine.remove(other)
        engine.shutdown()
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
