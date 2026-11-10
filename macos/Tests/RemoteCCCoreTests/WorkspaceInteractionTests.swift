import XCTest
import Observation
@testable import RemoteCCCore

@MainActor
final class WorkspaceInteractionTests: XCTestCase {
    func testSelectingLoadedTabDoesNotRestartRemoteValidation() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let file = env.home.appendingPathComponent("cached.txt")
        try "cached".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(files: env.files, agents: env.agents, config: env.config)
        await workspace.open(file.path)
        let tab = try XCTUnwrap(workspace.activeTab)
        let loadID = tab.loadID
        workspace.beginEditing(tab)
        tab.draft = "unsaved"
        workspace.activeTabId = nil
        await workspace.select(tab)
        XCTAssertEqual(workspace.activeTabId, tab.id)
        XCTAssertEqual(tab.loadID, loadID)
        XCTAssertFalse(tab.isValidating)
        XCTAssertEqual(tab.draft, "unsaved")
    }

    func testAsyncHydrationPreservesInterruptedMessagesAndIsIdempotent() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let store = try ChatStore(directory: env.home.appendingPathComponent("store"))
        var session = ChatSession(config: env.config)
        session.status = "working"
        session.messages = [ChatMessage(role: "assistant", text: "saved reply")]
        store.save([session]); store.flush()
        let engine = try ChatEngine(store: store, agents: env.agents, files: env.files)
        XCTAssertTrue(engine.session(session.id)?.messages.isEmpty == true)
        try await engine.hydrateAsync(session.id)
        XCTAssertEqual(engine.session(session.id)?.messages.first?.text, "saved reply")
        XCTAssertEqual(engine.session(session.id)?.messages.first?.interrupted, true)
        session.messages = []
        store.save([session]); store.flush()
        try await engine.hydrateAsync(session.id)
        XCTAssertEqual(engine.session(session.id)?.messages.count, 1)
    }

    func testChatDirectoryLinkBrowsesWithoutCreatingOrReplacingEditorTab() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let folder = env.home.appendingPathComponent("folder with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(files: env.files, agents: env.agents, config: env.config)
        let openedDirectory = try await workspace.openReference(file.path, line: 1)
        XCTAssertFalse(openedDirectory)
        let tab = try XCTUnwrap(workspace.activeTab)
        workspace.beginEditing(tab)
        tab.draft = "unsaved"
        let directory = try await workspace.openReference(folder.path + "/")
        XCTAssertTrue(directory)
        XCTAssertEqual(workspace.root, folder.path)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertTrue(workspace.activeTab === tab)
        XCTAssertEqual(tab.draft, "unsaved")
        XCTAssertTrue(workspace.rows.contains { $0.entry.path == file.path })
        do {
            try await workspace.openReference(folder.appendingPathComponent("missing").path)
            XCTFail("Missing paths should fail before opening a tab")
        } catch {}
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testEditorChangesDoNotInvalidateFileTreeObservation() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let file = env.home.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(files: env.files, agents: env.agents, config: env.config)
        await workspace.browse(env.home.path)
        await workspace.open(file.path)
        let tab = try XCTUnwrap(workspace.activeTab)
        let treeChanges = ChangeCount()
        withObservationTracking { _ = workspace.rows } onChange: { treeChanges.increment() }
        let editorChanges = ChangeCount()
        withObservationTracking { _ = tab.draft } onChange: { editorChanges.increment() }
        workspace.beginEditing(tab)
        tab.draft = "updated"
        XCTAssertEqual(treeChanges.value, 0)
        XCTAssertEqual(editorChanges.value, 1)
    }

    func testDirectoryPublishesLoadingBeforeChildrenAndCollapses() async throws {
        let env = try AgentEnvironment(); defer { env.cleanup() }
        let folder = env.home.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace(files: env.files, agents: env.agents, config: env.config)
        await workspace.browse(env.home.path)
        var sawLoading = false
        workspace.onChange = {
            if let row = workspace.rows.first(where: { $0.id == folder.path }), row.expanded && row.loading {
                sawLoading = true
            }
        }
        await workspace.toggle(folder.path)
        XCTAssertTrue(sawLoading)
        XCTAssertTrue(workspace.rows.contains { $0.entry.name == "note.txt" })
        XCTAssertFalse(workspace.rows.contains { $0.loading })
        await workspace.collapseAll()
        XCTAssertFalse(workspace.rows.contains { $0.entry.name == "note.txt" })
        XCTAssertFalse(workspace.rows.contains { $0.expanded || $0.loading })
        workspace.onChange = nil
    }
}

private final class ChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
