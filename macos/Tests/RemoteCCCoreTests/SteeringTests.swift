import XCTest
@testable import RemoteCCCore

/// Queue, steering and stop behaviour of the engine against the real remote agent.
final class SteeringTests: XCTestCase {
    /// The stand-in worker plus the two things the real one adds: steer and context usage.
    private static let worker = standInWorker
        .replacingOccurrences(of: "preferences:request.session.preferences||{}", with: "preferences:request.session.preferences||{},context:{usedTokens:128400,maxTokens:1000000}")
        .replacingOccurrences(of: " if(c.kind==='respond')", with: " if(c.kind==='steer'){message.blocks.push({type:'user',id:c.id,text:c.text,pending:true});write();}\n if(c.kind==='respond')")

    @MainActor
    private func busyEngine(_ env: AgentEnvironment, store: String) async throws -> (ChatEngine, String) {
        let engine = try ChatEngine(store: ChatStore(directory: env.home.appendingPathComponent(store)), agents: env.agents, files: env.files)
        engine.updateConnection(env.config, ConnectionState(status: .connected))
        let id = try engine.create(env.config).id
        try engine.send(id, text: "first")
        try await eventually { engine.session(id)?.status == "permission" }
        return (engine, id)
    }

    @MainActor
    func testSteerHandsAQueuedMessageToTheRunningReply() async throws {
        XCTAssertNotEqual(Self.worker, standInWorker)
        let env = try AgentEnvironment(workerSource: Self.worker); defer { env.cleanup() }
        let (engine, id) = try await busyEngine(env, store: "steer")
        XCTAssertEqual(engine.session(id)?.context, ContextUsage(usedTokens: 128_400, maxTokens: 1_000_000))

        try engine.submit(id, text: "later")
        try engine.submit(id, text: "now")
        let queued = try XCTUnwrap(engine.session(id)?.queue)
        XCTAssertEqual(queued.map(\.text), ["later", "now"])
        try await engine.steer(id, item: queued[1].id)

        // The steered message left the queue and shows inside the running reply.
        XCTAssertEqual(engine.session(id)?.queue?.map(\.text), ["later"])
        try await eventually { engine.session(id)?.messages.last?.blocks?.last?.type == "user" }
        let session = try XCTUnwrap(engine.session(id))
        XCTAssertEqual(session.messages.count, 2, "steering must not start a new reply")
        XCTAssertEqual(session.messages.last?.blocks?.last?.text, "now")
        XCTAssertEqual(session.messages.last?.blocks?.last?.pending, true)
        XCTAssertEqual(session.status, "permission")
        XCTAssertTrue(try engine.exportMarkdown(id).hasSuffix("## User\n\nnow"), "an export keeps what the user said mid-reply")

        // Typed and sent with the steer shortcut in one step.
        try engine.submit(id, text: "direct", steer: true)
        try await eventually { engine.session(id)?.messages.last?.blocks?.last?.text == "direct" }
        XCTAssertEqual(engine.session(id)?.queue?.map(\.text), ["later"])
        try await engine.stop(id); try await engine.remove(id)
        engine.shutdown()
    }

    @MainActor
    func testWorkerWithoutSteeringKeepsTheMessageAtTheHeadOfTheQueue() async throws {
        let worker = standInWorker.replacingOccurrences(of: " if(c.kind==='respond')",
            with: " if(c.kind==='steer'){fs.writeFileSync(file+'.result',JSON.stringify({ok:false,error:'未知会话请求'}));fs.renameSync(file,file+'.done');continue;}\n if(c.kind==='respond')")
        XCTAssertNotEqual(worker, standInWorker)
        let env = try AgentEnvironment(workerSource: worker); defer { env.cleanup() }
        let (engine, id) = try await busyEngine(env, store: "old-worker")
        try engine.submit(id, text: "later")
        try engine.submit(id, text: "now")
        let item = try XCTUnwrap(engine.session(id)?.queue?.last?.id)
        do { try await engine.steer(id, item: item); XCTFail("an old worker rejects steering") }
        catch { XCTAssertTrue(error.localizedDescription.contains("旧版本")) }
        XCTAssertEqual(engine.session(id)?.queue?.map(\.text), ["now", "later"])
        try await engine.stop(id); try await engine.remove(id)
        engine.shutdown()
    }

    @MainActor
    func testSteerWithALostAcknowledgementIsNotSentTwice() async throws {
        // This worker takes the message but its answer never confirms it.
        let worker = standInWorker.replacingOccurrences(of: " if(c.kind==='respond')",
            with: " if(c.kind==='steer'){message.blocks.push({type:'user',id:c.id,text:c.text});write();fs.writeFileSync(file+'.result',JSON.stringify({ok:false,uncertain:true,error:'确认超时'}));fs.renameSync(file,file+'.done');continue;}\n if(c.kind==='respond')")
        XCTAssertNotEqual(worker, standInWorker)
        let env = try AgentEnvironment(workerSource: worker); defer { env.cleanup() }
        let (engine, id) = try await busyEngine(env, store: "lost-ack")
        try engine.submit(id, text: "later")
        try engine.submit(id, text: "now")
        try? await engine.steer(id, item: try XCTUnwrap(engine.session(id)?.queue?.last?.id))
        try await eventually { engine.session(id)?.messages.last?.blocks?.last?.text == "now" }
        try await eventually { engine.session(id)?.queue?.map(\.text) == ["later"] }

        // The reply ends and the queue drains: only "later" is sent.
        try await engine.respond(id, permission: try XCTUnwrap(engine.session(id)?.permissions.first?.id), answer: ["allow": true])
        try await eventually { engine.session(id)?.messages.last?.blocks?.first?.text == "reply:later" }
        XCTAssertEqual(engine.session(id)?.messages.filter { $0.role == "user" }.map(\.text), ["first", "later"])
        try await engine.stop(id); try await engine.remove(id)
        engine.shutdown()
    }

    @MainActor
    func testStopShowsAtOnceAndPausesTheQueue() async throws {
        // This worker confirms a stop only after 400 ms, like a slow link.
        let worker = standInWorker.replacingOccurrences(of: "if(c.kind==='stop'){permissions=[];status='stopped';message.interrupted=true;write();}",
            with: "if(c.kind==='stop'){write();setTimeout(()=>{permissions=[];status='stopped';message.interrupted=true;write();},400);}")
        XCTAssertNotEqual(worker, standInWorker)
        let env = try AgentEnvironment(workerSource: worker); defer { env.cleanup() }
        let (engine, id) = try await busyEngine(env, store: "stop")
        try engine.submit(id, text: "queued")

        let stop = Task { @MainActor in try await engine.stop(id) }
        try await eventually(1) { engine.session(id)?.status == "stopping" }
        // The worker's own snapshot still says "permission"; it must not undo the stop.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.session(id)?.status, "stopping")
        try await stop.value
        let session = try XCTUnwrap(engine.session(id))
        XCTAssertEqual(session.status, "stopped")
        XCTAssertEqual(session.messages.count, 2, "a stopped reply must not start the queued message")
        XCTAssertEqual(session.queue?.map(\.text), ["queued"]); XCTAssertEqual(session.queuePaused, true)

        // With nothing running, steering a queued message sends it and resumes the queue.
        try await engine.steer(id, item: try XCTUnwrap(session.queue?.first?.id))
        try await eventually { engine.session(id)?.messages.last?.blocks?.first?.text == "reply:queued" }
        XCTAssertNil(engine.session(id)?.queue?.first)
        try await engine.stop(id); try await engine.remove(id)
        engine.shutdown()
    }

    func testContextUsageSurvivesSaveAndLoad() async throws {
        var session = ChatSession(config: ConnectionConfig(host: "dev", directory: "/work"), name: "saved")
        session.context = ContextUsage(usedTokens: 128_400, maxTokens: 1_000_000)
        let loaded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(loaded.context, session.context)
    }

    func testContextUsageLabel() async {
        XCTAssertEqual(ContextUsage(usedTokens: 128_400, maxTokens: 1_000_000).label, "128k / 1M")
        XCTAssertEqual(ContextUsage(usedTokens: 870, maxTokens: 200_000).label, "870 / 200k")
        XCTAssertEqual(ContextUsage(usedTokens: 1_250_000, maxTokens: 2_000_000).label, "1.3M / 2M")
        XCTAssertEqual(ContextUsage(usedTokens: 999_960, maxTokens: 1_000_000).label, "1M / 1M")
        XCTAssertEqual(ContextUsage(usedTokens: 150_000, maxTokens: 200_000).fraction, 0.75)
        XCTAssertEqual(ContextUsage(usedTokens: 5, maxTokens: 0).fraction, 0)
    }

    func testAccountSummaryOmitsUnreportedFields() async {
        let rows = AccountSummary.rows(["account": ["email": "dev@example.com", "organization": "", "subscriptionType": "max", "apiProvider": "firstParty", "tokenSource": "oauth"],
                                        "version": "2.1.312", "fastMode": "off", "quota": ["available": true]])
        XCTAssertEqual(rows.map(\.title), ["邮箱", "订阅", "服务提供方", "Claude Code"])
        XCTAssertEqual(rows.map(\.value), ["dev@example.com", "max", "Anthropic", "2.1.312"])
        XCTAssertTrue(AccountSummary.rows(["accountError": "未登录"]).isEmpty)
    }
}
