#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RemoteCCCore
import UserNotifications
import IOKit.pwr_mgt

enum SidePanel: String, CaseIterable, Identifiable {
    case files = "文件", changes = "变更", search = "搜索"
    var id: String { rawValue }
}

/// Bridges the core engine to SwiftUI. Core objects hold the state; this republishes their changes.
@MainActor
final class AppModel: ObservableObject {
    let accountStore = AccountStore()
    let transcript = TranscriptState()
    private(set) var engine: ChatEngine?
    private(set) var connections: SSHConnections?
    private var workspaces: [String: Workspace] = [:]

    @Published var selectedMachine: ConnectionConfig?
    @Published var savedMachines: [ConnectionConfig] = []
    @Published var syncingMachines = Set<String>()
    @Published var machineHistoryStatus: [String: String] = [:]
    @Published var reverseStates: [String: ReverseAccess] = [:]
    /// Setup problems found while connecting (missing Node.js or Claude, not logged in, …), per machine.
    @Published var machineHealth: [String: [HealthIssue]] = [:]
    @Published var checkingHealth = Set<String>()
    /// Held while any server can reach this Mac, so idle sleep does not cut it off. Lid close still sleeps.
    private var sleepAssertion: IOPMAssertionID = 0
    @Published var availableUpdate: String?
    private lazy var appUpdater = AppUpdater(model: self)
    private var updateChecksStarted = false
    @Published var checkingForUpdates = false
    @Published var activeId: String? {
        didSet {
            if activeId != oldValue {
                showSessionDetails = false
                transcript.update(active)
                if remembersConversation { RecentConversation().remember(activeId) }
            }
        }
    }
    @Published var showArchived = false
    @Published var searchText = ""
    @Published var toast: String?
    /// The conversation's "…" menu, opened from the conversation header.
    @Published var sessionMenuVisible = false
    @Published var panel: SidePanel = .files
    @Published var sidebarVisible = true {
        didSet {
            if sidebarVisible { sidebarFocus = UUID() }
            else { focusWorkspace() }
        }
    }
    @Published var editorFocus = UUID()
    @Published var sidebarFocus = UUID()

    func focusWorkspace() {
        if showingChat || activeWorkspace?.activeTab == nil { composerFocus = UUID() }
        else { editorFocus = UUID() }
    }

    func openPanel(_ value: SidePanel) {
        panel = value; showFiles = true; sidebarVisible = true
        sidebarFocus = UUID()
    }
    @Published var showFiles = false {
        didSet { if showFiles { sidebarVisible = true } }
    }
    var proposedProject: String?
    @Published var showingChat = true
    private var workspaceSearches: [String: WorkspaceSearchState] = [:]

    func searchState(for workspace: Workspace) -> WorkspaceSearchState {
        guard let key = activeId else { return WorkspaceSearchState() }
        if let state = workspaceSearches[key] { return state }
        let state = WorkspaceSearchState()
        workspaceSearches[key] = state
        return state
    }

    func focusChat() {
        showingChat = true
        composerFocus = UUID()
    }

    @Published var composerFocus = UUID()
    @Published var sessionToolsSection = "skills"
    private var transcriptViewports: [String: TranscriptViewport] = [:]
    func transcriptViewport(for id: String) -> TranscriptViewport {
        if let state = transcriptViewports[id] { return state }
        let state = TranscriptViewport()
        transcriptViewports[id] = state
        return state
    }

    @Published var showSessionDetails = false
    @Published var historyStatus = ""
    @Published private var transferStatuses: [ConnectionConfig: String] = [:]
    @Published private var batchUploadProgress: [String: String] = [:]
    var transferStatus: String {
        guard let active else { return "" }
        return batchUploadProgress[active.id] ?? transferStatuses[active.config] ?? ""
    }
    @Published var drafts: [String: String] = [:]
    @Published var attachments: [String: [Attachment]] = [:]
    @Published var presentation: AppPresentation?
    @Published var fatalError: String?
    #if DEBUG
    #endif

    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "task-notifications")
    var failedUploadDirectories: [String: [URL: String]] = [:]
    @Published var failedUploads: [String: [URL]] = [:]
    @Published var uploadingSessions = Set<String>()
    @Published var unreadSessions = Set<String>()
    @Published var historyRefreshErrors: [String: String] = [:]
    @Published var refreshingHistory = Set<String>()
    private var historyPoll: Task<Void, Never>?
    private var notificationTracker = TaskNotificationTracker()
    private var notificationRequestID = UUID()
    @Published var notificationsAuthorizing = false
    @Published var notificationTestStatus = ""
    @Published var notificationTestRunning = false
    private var toastTask: Task<Void, Never>?
    private var capabilityRetry: [String: Date] = [:]
    private var capabilityRequests = Set<String>()
    private let lastConnectionKey = "last-connection"
    private var remembersConversation = false

    /// Isolated UI previews and rendering tests never connect to saved machines.
    init(previewSession: ChatSession) {
        activeId = previewSession.id
        transcript.update(previewSession)
    }

    init() {
        drafts = UserDefaults.standard.dictionary(forKey: "composer-drafts") as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: "composer-attachments") {
            attachments = (try? JSONDecoder().decode([String: [Attachment]].self, from: data)) ?? [:]
        }
        #if DEBUG
        if Bundle.main.bundleIdentifier == "local.claudemirror.demo" {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-demo-" + UUID().uuidString)
                let store = try ChatStore(directory: folder)
                let examples = DemoData.sessions()
                store.save(examples); store.flush()
                let resources = try ServerResources(directory: Bundle.main.resourceURL!.appendingPathComponent("server"))
                let agents = AgentClient(launcher: DemoLauncher(), resources: resources)
                let files = RemoteFiles(agents: agents, cacheDirectory: folder.appendingPathComponent("cache"))
                let engine = try ChatEngine(store: store, agents: agents, files: files)
                self.engine = engine
                savedMachines = [DemoData.config, ConnectionConfig(host: "staging", directory: "/workspace", name: "测试服务器")]
                selectedMachine = DemoData.config
                activeId = examples[0].id
                try engine.hydrate(examples[0].id)
                engine.updateConnection(DemoData.config, ConnectionState(status: .connected))
                historyStatus = "已同步 3 条对话"
                transcript.update(active)
                engine.onChange = { [weak self] in self?.engineChanged() }
            } catch { fatalError = error.localizedDescription }
            return
        }
        #endif
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RemoteCC Native")
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RemoteCC Native")
            guard let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("server") else { throw RemoteError("找不到应用资源") }
            let resources = try ServerResources(directory: resourceDirectory)
            let connections = try SSHConnections(askpassPath: Bundle.main.url(forAuxiliaryExecutable: "ClaudockAskpass")?.path)
            let agents = AgentClient(launcher: connections, resources: resources)
            let files = RemoteFiles(agents: agents, cacheDirectory: caches)
            let engine = try ChatEngine(store: try ChatStore(directory: support), agents: agents, files: files)
            self.connections = connections; self.engine = engine
            engine.onChange = { [weak self] in self?.engineChanged() }
            engine.onTranscriptChange = { [weak self] ids in
                guard let self, let id = self.activeId, ids.contains(id) else { return }
                self.transcript.update(self.active)
            }
            engine.onError = { [weak self] in self?.show($0) }
            connections.onState = { [weak self] config, state in
                Task { @MainActor in self?.connectionChanged(config, state) }
            }
            connections.onReverse = { [weak self] config, access in
                Task { @MainActor in
                    guard let self else { return }
                    self.reverseStates[config.key] = access
                    self.updateSleepAssertion()
                    if !access.error.isEmpty { self.show("\(config.displayName)：\(access.error)") }
                }
            }
            connections.onRecovered = { [weak self] config in
                Task { @MainActor in await self?.recovered(config) }
            }
            agents.onFileChange = { [weak self] config, directories in
                Task { @MainActor in self?.filesChanged(config, directories) }
            }
            files.onProgress = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    if let error = progress.error { self.transferStatuses[progress.config] = "\(progress.name) · 失败：\(error)" }
                    else if progress.finished { self.transferStatuses[progress.config] = "\(progress.name) · 完成" }
                    else { self.transferStatuses[progress.config] = "\(progress.name) · \(progress.total > 0 ? min(99, progress.bytes * 100 / progress.total) : 0)%" }
                }
            }
            savedMachines = machineStore.load(discovered: sessions.map(\.config) + [lastConnection].compactMap { $0 })
            selectedMachine = lastConnection ?? savedMachines.first
            remembersConversation = true
            if let id = RecentConversation().resolve(in: sessions.filter { !machineStore.removedKeys.contains($0.config.key) }) { select(id) }
            autoConnect()
            historyPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if let id = self.activeId, self.isConnected { await self.refreshVisibleHistory(id, report: false) }
                }
            }
        } catch { fatalError = error.localizedDescription }
    }

    // MARK: State access

    var sessions: [ChatSession] { engine?.sessions ?? [] }
    var active: ChatSession? { activeId.flatMap { engine?.session($0) } }
    func activityLabel(_ session: ChatSession) -> String {
        switch engine?.taskConnection(session.id) {
        case .offline: return "远端任务待重连"
        case .restoring: return "正在恢复远端任务…"
        case .failed: return "任务同步失败"
        default: break
        }
        if session.isBusy { return statusLabel(session.status) }
        if session.runningBackgroundTaskCount > 0 { return "后台运行 · \(session.runningBackgroundTaskCount) 项" }
        return statusLabel(session.status)
    }
    var sortedSessions: [ChatSession] {
        sessions.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return a.updatedAt > b.updatedAt
        }
    }
    var lastConnection: ConnectionConfig? {
        get { UserDefaults.standard.data(forKey: lastConnectionKey).flatMap { try? JSONDecoder().decode(ConnectionConfig.self, from: $0) } }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastConnectionKey) }
    }
    var currentConfig: ConnectionConfig? { selectedMachine ?? active?.config ?? lastConnection }
    func projectMissing(_ session: ChatSession) -> Bool { engine?.projectMissing(session.config) == true }

    var machineSessions: [ChatSession] { sortedSessions.filter { $0.config.key == currentConfig?.key } }

    func selectMachine(_ config: ConnectionConfig) {
        selectedMachine = config
        lastConnection = config
        activeId = nil
        searchText = ""; showArchived = false
        historyStatus = machineHistoryStatus[config.key] ?? ""
        if engine?.connectionState(config).status != .connected {
            perform { try await self.connect(config) }
        }
    }

    func updateMachine(_ original: ConnectionConfig, with input: ConnectionConfig, password: String?) async throws {
        guard let engine, let connections else { throw RemoteError("连接服务尚未就绪") }
        let config = try input.validated()
        guard !syncingMachines.contains(original.key), !syncingMachines.contains(config.key) else { throw RemoteError("正在同步机器，请稍后再试") }
        guard !engine.sessions.contains(where: { $0.config.key == original.key && $0.isBusy && $0.status != "detached" }) else { throw RemoteError("请等待这台机器的任务结束后再修改连接") }
        guard !engine.sessions.contains(where: { $0.config.key == original.key && workspaces[$0.id]?.hasUnsavedEdits == true }) else { throw RemoteError("请先保存这台机器上正在编辑的文件") }
        guard original.key == config.key || !savedMachines.contains(where: { $0.key == config.key }) else { throw RemoteError("该主机和端口已存在") }
        syncingMachines.insert(original.key)
        syncingMachines.insert(config.key)
        defer { syncingMachines.remove(original.key); syncingMachines.remove(config.key) }
        engine.detach(original)
        engine.agents.close(original)
        await connections.disconnect(original)
        reverseStates[original.key] = nil
        do { try await connections.connect(config, password: password) }
        catch {
            await connections.disconnect(config)
            throw RemoteError(ConnectionAdvice.explain(error.localizedDescription))
        }
        let affected = engine.sessions.filter { $0.config.key == original.key }.map(\.id)
        try engine.replaceMachine(original, with: config)
        for id in affected { workspaces[id] = nil }
        savedMachines.removeAll { $0.key == original.key }
        rememberMachine(config)
        if let activeId, !affected.contains(activeId) { self.activeId = nil }
        selectedMachine = config
        lastConnection = config
        await discoverHistory(config)
        await engine.restore(config)
    }

    private let machineStore = SavedMachineStore()

    func removeMachine(_ config: ConnectionConfig) async throws {
        guard !syncingMachines.contains(config.key) else { throw RemoteError("正在同步主机，请稍后再试") }
        guard !sessions.contains(where: { $0.config.key == config.key && workspaces[$0.id]?.hasUnsavedEdits == true }) else {
            throw RemoteError("请先保存这台主机上正在编辑的文件")
        }
        syncingMachines.insert(config.key)
        defer { syncingMachines.remove(config.key) }
        engine?.detach(config)
        engine?.agents.close(config)
        await connections?.disconnect(config)
        reverseStates[config.key] = nil
        updateSleepAssertion()
        savedMachines.removeAll { $0.key == config.key }
        machineStore.save(savedMachines)
        machineStore.markRemoved(config.key)
        if active?.config.key == config.key { activeId = nil }
        if selectedMachine?.key == config.key { selectedMachine = savedMachines.first }
        if lastConnection?.key == config.key { lastConnection = selectedMachine }
    }

    func renameMachine(_ config: ConnectionConfig, name: String) {
        var renamed = config
        renamed.name = name
        do {
            renamed = try renamed.validated()
            rememberMachine(renamed)
            if selectedMachine?.key == renamed.key { selectedMachine = renamed; lastConnection = renamed }
        } catch { show(error.localizedDescription) }
    }

    func setReverseAccess(_ machine: ConnectionConfig, enabled: Bool) {
        if enabled {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "允许 \(machine.displayName) 登录这台 Mac？"
            alert.informativeText = "开启后，服务器上的程序可以通过本应用的连接，以你的身份登录这台 Mac 并执行命令。只在你完全信任这台服务器、并且确实需要从服务器访问本机时开启。关闭后立即撤销。"
            alert.addButton(withTitle: "仍要开启")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { objectWillChange.send(); return }
        }
        var updated = savedMachines.first { $0.key == machine.key } ?? machine
        updated.reverseAccess = enabled ? true : nil
        rememberMachine(updated)
        if selectedMachine?.key == updated.key { selectedMachine = updated; lastConnection = updated }
        if !enabled { reverseStates[updated.key] = nil; updateSleepAssertion() }
        Task { await connections?.setReverseAccess(updated, enabled: enabled) }
    }

    func copyReverseCommand(_ machine: ConnectionConfig) {
        guard let command = reverseStates[machine.key]?.command else { show("反向连接尚未建立"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        show("已复制，在 \(machine.displayName) 上运行即可连接本机")
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func startUpdateChecks() {
        guard !updateChecksStarted, Bundle.main.bundleIdentifier == "local.remotecc.native" else { return }
        updateChecksStarted = true
        appUpdater.start()
    }

    func checkForUpdates(manual: Bool) async {
        startUpdateChecks()
        appUpdater.check(manual: manual)
    }

    func reverseStatus(_ machine: ConnectionConfig) -> String {
        if let access = reverseStates[machine.key] {
            if access.socketPath != nil { return "反向连接已建立" }
            if !access.error.isEmpty { return access.error }
        }
        return engine?.connectionState(machine).status == .connected ? "正在建立反向连接…" : "连接这台机器后自动建立"
    }

    private func updateSleepAssertion() {
        let active = reverseStates.values.contains { $0.socketPath != nil }
        if active, sleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "镜像 Claude：服务器正在使用反向连接" as CFString, &id) == kIOReturnSuccess { sleepAssertion = id }
        } else if !active, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    private func rememberMachine(_ config: ConnectionConfig) {
        machineStore.allow(config.key)
        if let index = savedMachines.firstIndex(where: { $0.key == config.key }) { savedMachines[index] = config }
        else { savedMachines.append(config) }
        machineStore.save(savedMachines)
    }
    var connectionState: ConnectionState { currentConfig.flatMap { engine?.connectionState($0) } ?? ConnectionState() }
    var isConnected: Bool { connectionState.status == .connected }
    var hasUnsavedEdits: Bool { workspaces.values.contains(where: \.hasUnsavedEdits) }

    func workspace(for session: ChatSession) -> Workspace? {
        guard let engine else { return nil }
        let key = session.id
        if let existing = workspaces[key] { return existing }
        let workspace = Workspace(files: engine.files, agents: engine.agents, config: session.config)
        workspace.touchedFiles = { [weak self] in self?.touchedFiles(session.id) ?? [] }
        workspaces[key] = workspace
        return workspace
    }
    var activeWorkspace: Workspace? { active.flatMap(workspace(for:)) }

    private func touchedFiles(_ id: String) -> Set<String> {
        var result = Set<String>()
        for block in engine?.session(id)?.messages.last?.blocks ?? [] where ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(block.name ?? "") {
            if let file = block.input?["file_path"]?.string ?? block.input?["notebook_path"]?.string { result.insert(file) }
        }
        return result
    }

    private var lastBusy: [String: Bool] = [:]
    private func engineChanged() {
        transcript.update(active)
        objectWillChange.send()
        for session in sessions {
            let background = Set((session.tasks?.array ?? []).filter { $0["status"]?.string == "running" && $0["ambient"]?.bool != true }.compactMap { $0["id"]?.string })
            let isViewed = session.id == activeId && NSApp.isActive && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
            if let body = notificationTracker.update(id: session.id, status: session.status, background: background,
                connected: engine?.connectionState(session.config).status == .connected, isViewed: isViewed) {
                unreadSessions.insert(session.id)
                if notificationsEnabled {
                    Task {
                        do { try await postNotification(id: session.id, title: "RemoteCC · " + session.host, body: body, sessionId: session.id) }
                        catch { show("系统通知发送失败：" + error.localizedDescription) }
                    }
                }
            }
        }
        NSApp.dockTile.badgeLabel = unreadSessions.isEmpty ? nil : String(unreadSessions.count)
        for session in sessions where session.id == activeId {
            let busy = session.isBusy
            // Without working watches, follow the turn's end instead of live pushes.
            if lastBusy[session.id] == true, !busy, isConnected { Task { await workspace(for: session)?.reload(force: true) } }
            lastBusy[session.id] = busy
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// Runs async work and surfaces its failure; the UI's buttons all go through here.
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do { try await work() } catch { self?.show(error.localizedDescription) }
        }
    }

    // MARK: Connection

    private func autoConnect() {
        guard let config = currentConfig, lastConnection != nil else { return }
        perform { try await self.connect(config, preservingConversation: true) }
    }

    func connect(_ input: ConnectionConfig, password: String? = nil, preservingConversation: Bool = false) async throws {
        guard engine != nil, let connections else { return }
        var config = try input.validated()
        // Connecting a machine never depends on a remembered project's existence.
        config.directory = "~"
        guard !syncingMachines.contains(config.key) else { return }
        syncingMachines.insert(config.key)
        defer { syncingMachines.remove(config.key) }
        selectedMachine = config
        if !preservingConversation { activeId = nil }
        searchText = ""; showArchived = false
        do { try await connections.connect(config, password: password) }
        catch { throw RemoteError(ConnectionAdvice.explain(error.localizedDescription)) }
        rememberMachine(config)
        if selectedMachine?.key == config.key { lastConnection = config }
        await prepareMachine(config)
        if preservingConversation, let active, active.config.key == config.key {
            await refreshVisibleHistory(active.id, report: false)
        }
    }

    /// Everything after SSH itself: start the agent, check the server's setup, then load history.
    /// Setup problems become a persistent checklist on the machine instead of a passing toast.
    private func prepareMachine(_ input: ConnectionConfig) async {
        guard let engine else { return }
        var config = input
        do {
            let info = try await engine.agents.info(config)
            config.directory = info.home
            rememberMachine(config)
            if selectedMachine?.key == config.key { selectedMachine = config; lastConnection = config }
            machineHealth[config.key] = MachineHealth.issues(startError: nil, info: info, status: nil)
            let checking = Task { await self.refreshHealth(config, info: info) }
            await discoverHistory(config)
            await engine.restore(config)
            await checking.value
        } catch {
            let issues = MachineHealth.issues(startError: error, info: nil, status: nil)
            machineHealth[config.key] = issues
            machineHistoryStatus[config.key] = issues.isEmpty ? "SSH 已连接，历史加载失败，可重试" : "SSH 已连接，服务器还需要设置"
            if selectedMachine?.key == config.key { historyStatus = machineHistoryStatus[config.key]! }
            if issues.isEmpty { show(error.localizedDescription) }
        }
    }

    /// Asks the server whether Claude is installed and logged in. Failures leave the checklist as it was.
    func refreshHealth(_ config: ConnectionConfig, info: ServerInfo? = nil) async {
        guard let engine, !checkingHealth.contains(config.key) else { return }
        checkingHealth.insert(config.key)
        defer { checkingHealth.remove(config.key) }
        do {
            let server: ServerInfo
            if let info { server = info } else { server = try await engine.agents.info(config) }
            let status = ClaudeStatus(json: try await engine.agents.call(config, "file", ["operation": "claudeStatus"], timeout: 45))
            machineHealth[config.key] = MachineHealth.issues(startError: nil, info: server, status: status)
        } catch let error as RemoteSetupError {
            machineHealth[config.key] = MachineHealth.issues(startError: error, info: nil, status: nil)
        } catch {
            if info == nil { show("检查服务器失败：" + error.localizedDescription) }
        }
    }

    /// "重新检查": after installing or logging in, rerun the whole preparation for this machine.
    func recheckMachine(_ config: ConnectionConfig) {
        Task {
            guard engine?.connectionState(config).status == .connected else {
                perform { try await self.connect(config) }
                return
            }
            let blockedBefore = machineHealth[config.key]?.contains { $0.kind == .node } == true
            if blockedBefore { await prepareMachine(config) } else { await refreshHealth(config) }
            if machineHealth[config.key]?.isEmpty ?? true { show("\(config.displayName) 已准备就绪") }
        }
    }

    func openRemoteSetup(_ config: ConnectionConfig) { presentation = .remoteSetup(config) }

    /// Opens Terminal on the server running `command`, reusing this app's SSH connection.
    func runInTerminal(_ config: ConnectionConfig, command: String) {
        guard let connections else { return }
        let line = connections.terminalCommand(config, remoteCommand: command)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mirror-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/sh\nrm -f \"$0\"\nclear\necho '正在连接 \(config.displayName.replacingOccurrences(of: "'", with: ""))，完成后可以关闭此窗口。'\n" + line + "\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch { copyCommand(line, note: "无法打开终端，已复制命令，请粘贴到终端运行") }
    }

    func copyCommand(_ command: String, note: String = "已复制命令") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        show(note)
    }

    // MARK: Password-free login

    private func keyOfferKey(_ config: ConnectionConfig) -> String { "declined-key-login:" + config.key }

    /// After a password login, offer once per machine to switch to a dedicated key.
    func offerKeyLogin(_ config: ConnectionConfig) {
        guard config.authentication == .password, !UserDefaults.standard.bool(forKey: keyOfferKey(config)) else { return }
        presentation = .keyLogin(config)
    }

    func declineKeyLogin(_ config: ConnectionConfig) {
        UserDefaults.standard.set(true, forKey: keyOfferKey(config))
        presentation = nil
    }

    /// Creates ~/.ssh/claude_mirror_ed25519 if needed, authorizes it on the server over the
    /// current connection, proves it logs in alone, and only then switches the machine to it.
    func setUpKeyLogin(_ input: ConnectionConfig) async throws {
        guard let connections else { throw RemoteError("连接服务尚未就绪") }
        let config = savedMachines.first { $0.key == input.key } ?? input
        let path = LoginKeySetup.defaultKeyPath
        let publicKey = try LoginKeySetup.ensureKey(at: path)
        let output = try await connections.runScript(config, script: LoginKeySetup.authorizeScript(publicKey: publicKey))
        guard output.contains("__RCC_KEY_OK__") else { throw RemoteError("服务器没有确认添加密钥") }
        var updated = config
        updated.authentication = .keyFile
        updated.identityFile = path
        do { try await connections.verifyLogin(updated) }
        catch { throw RemoteError("密钥已添加，但服务器不接受密钥登录（可能禁用了公钥认证）。仍可继续使用密码。\n" + error.localizedDescription) }
        rememberMachine(updated)
        connections.updateConfig(updated)
        if selectedMachine?.key == updated.key { selectedMachine = updated; lastConnection = updated }
        show("已设置免密登录，以后会自动连接 \(updated.displayName)")
    }

    func disconnect() {
        guard let engine, let connections, let config = currentConfig else { return }
        engine.detach(config)
        engine.agents.close(config)
        Task { await connections.disconnect(config) }
    }

    private func connectionChanged(_ config: ConnectionConfig, _ state: ConnectionState) {
        guard let engine else { return }
        let wasConnected = engine.connectionState(config).status == .connected
        // The forward dies with the master; the next connection re-establishes and reports it.
        if state.status != .connected, reverseStates[config.key] != nil { reverseStates[config.key] = nil; updateSleepAssertion() }
        engine.updateConnection(config, state)
        if wasConnected, state.status != .connected { engine.detach(config) }
    }

    /// After an automatic reconnect the tree reloads, watches return and tasks are rejoined.
    private func recovered(_ config: ConnectionConfig) async {
        guard let engine else { return }
        engine.files.invalidate(config)
        await engine.restore(config)
        try? await engine.refreshProjects(config)
        if active?.config.key == config.key { await activeWorkspace?.reload(force: true) }
    }

    private func filesChanged(_ config: ConnectionConfig, _ directories: [String]) {
        guard let active, active.config.key == config.key else { return }
        Task { await workspace(for: active)?.filesChanged(directories) }
    }

    func discoverHistory(_ config: ConnectionConfig) async {
        guard let engine else { return }
        machineHistoryStatus[config.key] = "正在同步历史…"
        if currentConfig?.key == config.key { historyStatus = "正在同步历史…" }
        do {
            let result = try await engine.discoverHistory(config)
            machineHistoryStatus[config.key] = "已同步 \(result.count) 条对话" + (result.unreadable > 0 ? " · \(result.unreadable) 条不可读" : "")
        } catch { machineHistoryStatus[config.key] = "历史同步失败，点击刷新重试"; show(error.localizedDescription) }
        if currentConfig?.key == config.key { historyStatus = machineHistoryStatus[config.key] ?? "" }
    }

    // MARK: Conversations

    private var selectionRefresh: Task<Void, Never>?
    private var historyRefreshedAt: [String: Date] = [:]

    func select(_ id: String) {
        guard let engine, let session = engine.session(id), activeId != id else { return }
        selectionRefresh?.cancel()
        activeId = id
        unreadSessions.remove(id)
        NSApp.dockTile.badgeLabel = unreadSessions.isEmpty ? nil : String(unreadSessions.count)
        selectedMachine = savedMachines.first(where: { $0.key == session.config.key }) ?? session.config
        selectionRefresh = Task {
            do {
                try await engine.hydrateAsync(id)
                try Task.checkCancellation()
                // Let selection and cached content paint before starting background RPCs.
                try await Task.sleep(for: .milliseconds(150))
                guard activeId == id, let current = engine.session(id),
                      engine.connectionState(current.config).status == .connected else { return }
                if engine.taskConnection(id) == .restoring || engine.taskConnection(id) == .failed {
                    await engine.attach(id)
                    try Task.checkCancellation()
                }
                let workspace = workspace(for: current)
                if workspace?.root == nil { Task { await workspace?.browse(current.directory) } }
                if current.historyLoaded == false {
                    try await engine.loadHistory(id)
                    historyRefreshedAt[id] = Date()
                }
                try Task.checkCancellation()
                guard activeId == id else { return }
                refreshCapabilities()
                if Date().timeIntervalSince(historyRefreshedAt[id] ?? .distantPast) >= 30 {
                    await refreshVisibleHistory(id, report: false)
                }
            } catch is CancellationError {} catch {
                if activeId == id { show(error.localizedDescription) }
            }
        }
    }

    func refreshVisibleHistory(_ id: String, report: Bool = true) async {
        guard let engine, !refreshingHistory.contains(id), let session = engine.session(id),
              engine.connectionState(session.config).status == .connected else { return }
        refreshingHistory.insert(id)
        historyRefreshedAt[id] = Date()
        defer { refreshingHistory.remove(id) }
        do {
            try await engine.refreshHistory(id)
            try await engine.refreshProjects(session.config, directories: [session.directory])
            historyRefreshErrors[id] = nil
        }
        catch {
            historyRefreshErrors[id] = error.localizedDescription
            if report { show(error.localizedDescription) }
        }
    }

    var attentionSessions: [ChatSession] {
        sortedSessions.filter { $0.isBusy || !$0.permissions.isEmpty || unreadSessions.contains($0.id) ||
            $0.runningBackgroundTaskCount > 0 || $0.transportError != nil || engine?.taskConnection($0.id) == .restoring }
    }

    func newConversation() {
        guard let engine else { return }
        searchText = ""; showArchived = false
        guard let config = currentConfig else {
            activeId = nil
            composerFocus = UUID()
            return
        }
        perform {
            let session = try engine.create(config, preferences: self.active?.preferences)
            if self.activeId == nil { self.drafts[session.id] = self.drafts.removeValue(forKey: "welcome-" + config.key) }
            self.select(session.id)
            self.composerFocus = UUID()
        }
    }

    func newConversation(in source: ChatSession) {
        guard let engine else { return }
        searchText = ""; showArchived = false
        perform {
            try await engine.requireProject(source.config)
            self.select(try engine.create(source.config, preferences: source.preferences).id)
            self.composerFocus = UUID()
        }
    }

    func chooseProject(_ directory: String) async throws {
        guard let engine, var config = currentConfig, isConnected else { throw RemoteError("请先连接服务器") }
        let source = active
        let listing = try await engine.files.list(config, directory, hidden: false, force: true)
        guard listing.path != source?.directory else { return }
        config.directory = listing.path
        let session = try engine.create(config, preferences: source?.preferences)
        // Move only the unsent draft; the old conversation and its running task remain bound to their project.
        if let source {
            drafts[session.id] = drafts.removeValue(forKey: source.id)
            attachments[session.id] = attachments.removeValue(forKey: source.id)
        }
        searchText = ""; showArchived = false
        select(session.id)
        composerFocus = UUID()
    }

    func createProject(in parent: String, name: String) async throws -> String {
        guard let engine, let config = currentConfig, isConnected else { throw RemoteError("请先连接服务器") }
        let entry = try await engine.files.createFolder(config, in: parent, name: name)
        return entry.path
    }

    func createWorktree(_ branch: String) async throws {
        guard let source = active, let engine, isConnected else { throw RemoteError("请先连接项目所在的机器") }
        let result = try await engine.files.run(source.config, "createWorktree", ["branch": .string(branch)], timeout: 90)
        guard let directory = result["path"]?.string else { throw RemoteError("工作区已创建，但远端没有返回路径") }
        var config = source.config; config.directory = directory
        do { select(try engine.create(config, preferences: source.preferences).id) }
        catch { throw RemoteError("工作区已创建在 \(directory)，新建对话失败：\(error.localizedDescription)") }
    }

    func openProjectPicker(_ directory: String? = nil) {
        proposedProject = directory ?? active?.directory
        showProjectPicker = true
    }

    func refreshCapabilities(force: Bool = false) {
        guard let engine, let session = active, session.historyLoaded != false, isConnected else { return }
        let id = session.id
        if !force, let fetched = session.capabilities?.fetchedAt, Date().timeIntervalSince1970 * 1000 - fetched < 300_000 { return }
        if capabilityRequests.contains(id) || (capabilityRetry[id] ?? .distantPast) > Date() { return }
        capabilityRequests.insert(id)
        Task {
            do { try await engine.capabilities(id, refresh: force); capabilityRetry[id] = nil }
            catch { capabilityRetry[id] = Date().addingTimeInterval(10) }
            capabilityRequests.remove(id)
        }
    }

    func submit(text: String) {
        guard let engine, let id = activeId else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments[id] ?? []
        guard !value.isEmpty || !files.isEmpty else { return }
        guard isConnected else { show("请先连接 SSH 服务器"); return }
        perform {
            if value.hasPrefix("/"), files.isEmpty, let capabilities = self.active?.capabilities, let interaction = commandInteraction(capabilities, text: value, preferences: self.active?.preferences) {
                try await self.run(interaction, id: id)
                return
            }
            if let session = engine.session(id) { try await engine.requireProject(session.config) }
            try engine.submit(id, text: value, attachments: files)
            self.attachments[id] = nil
            self.drafts[id] = ""
        }
    }

    func openTools(_ section: String) {
        sessionToolsSection = section
        showSessionTools = true
    }

    /// Quick actions use the server catalogue and the normal Claude command path.
    /// They do not consume or clear the user's pending draft/attachments.
    func runRemoteCommand(_ name: String) {
        guard let engine, let session = active, isConnected else { show("请先连接并打开对话"); return }
        guard !session.isBusy else { show("请等待当前回复结束"); return }
        perform {
            let catalogue = try await engine.capabilities(session.id)
            guard let command = catalogue.commands.first(where: { $0.name == name && $0.builtin == true }) else {
                throw RemoteError("远端 Claude 不支持 /" + name)
            }
            try engine.submit(session.id, text: "/" + command.name)
        }
    }

    private func run(_ interaction: CommandInteraction, id: String) async throws {
        guard let engine else { return }
        switch interaction.kind {
        case .newConversation:
            drafts[id] = ""
            let session = try engine.create(active?.config ?? currentConfig!, preferences: active?.preferences)
            select(session.id)
        case .model where !interaction.argument.isEmpty:
            try await engine.selectModel(id, interaction.argument); drafts[id] = ""
        case .effort where !interaction.argument.isEmpty:
            try await engine.selectEffort(id, interaction.argument); drafts[id] = ""
        default:
            commandPicker = interaction
        }
    }

    func applyCommandPicker(_ interaction: CommandInteraction, value: String) {
        guard let engine, let id = activeId else { return }
        commandPicker = nil
        perform {
            switch interaction.kind {
            case .model: try await engine.selectModel(id, value)
            case .effort: try await engine.selectEffort(id, value)
            default: try engine.submit(id, text: "/" + interaction.command + " " + value)
            }
            self.drafts[id] = ""
        }
    }

    func stop() {
        guard let engine, let id = activeId else { return }
        perform { try await engine.stop(id) }
    }

    func respond(_ permission: PermissionRequest, answer: JSON) async throws {
        guard let engine, let id = activeId else { return }
        try await engine.respond(id, permission: permission.id, answer: answer)
    }

    func archiveProject(_ project: ChatSession, archived: Bool, confirmed: Bool = false) {
        guard let engine else { return }
        let sessions = machineSessions.filter { $0.projectKey == project.projectKey }
        guard !sessions.contains(where: { $0.isBusy || $0.queue?.isEmpty == false }) else {
            show("请先完成或停止此项目中的任务"); return
        }
        if archived && !confirmed {
            presentation = .confirmation(WorkbenchConfirmation(title: "从侧栏移除项目？",
                detail: "\(project.directory)\n将归档该项目的 \(sessions.count) 条对话，可从已归档列表恢复。远端文件夹和聊天历史不会删除。",
                actionTitle: "移除项目") { [weak self] in self?.archiveProject(project, archived: true, confirmed: true) })
            return
        }
        perform {
            for session in sessions { try engine.setArchived(session.id, archived) }
            if sessions.contains(where: { $0.id == self.activeId }) { self.activeId = nil }
        }
    }

    func deleteProjectHistory(_ project: ChatSession, confirmed: Bool = false) {
        guard let engine else { return }
        if !confirmed {
            presentation = .confirmation(WorkbenchConfirmation(title: "删除此项目的远端聊天记录？",
                detail: project.directory + "\n所有匹配此目录的聊天记录将移入远端回收目录，本地列表同步移除。项目文件不受影响。请先关闭其他客户端中此目录的 Claude 会话。",
                actionTitle: "移入远端回收目录", destructive: true) { [weak self] in self?.deleteProjectHistory(project, confirmed: true) })
            return
        }
        perform {
            let trash = try await engine.trashProjectHistory(project.id)
            if let active = self.activeId, engine.session(active) == nil { self.activeId = nil }
            self.workspaces = self.workspaces.filter { engine.session($0.key) != nil }
            if let trash { copyToPasteboard(trash); self.show("已移入远端回收目录，恢复路径已复制") }
            else { self.show("此目录没有可删除的远端聊天记录") }
        }
    }

    func deleteConversation(_ session: ChatSession, confirmed: Bool = false) {
        guard let engine else { return }
        if !confirmed {
            presentation = .confirmation(WorkbenchConfirmation(title: "删除这条本地聊天记录？",
                detail: "远端 Claude 的历史不会被删除。", actionTitle: "删除", destructive: true) { [weak self] in self?.deleteConversation(session, confirmed: true) })
            return
        }
        perform {
            try await engine.remove(session.id)
            self.workspaces[session.id] = nil
            self.workspaceSearches[session.id] = nil
            if self.activeId == session.id {
                self.activeId = nil
                if let next = self.sortedSessions.first?.id { self.select(next) }
            }
        }
    }

    func exportConversation(_ session: ChatSession) {
        guard let engine else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.name.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try engine.exportMarkdown(session.id).write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Files

    func open(_ file: String, line: Int? = nil) {
        guard isConnected else { show("请先连接 SSH 服务器"); return }
        guard let workspace = activeWorkspace else { return }
        Task {
            do {
                let directory = try await workspace.openReference(file, line: line)
                guard workspace === activeWorkspace else { return }
                if directory {
                    openPanel(.files)
                } else {
                    showingChat = false
                    editorFocus = UUID()
                }
            } catch {
                if workspace === activeWorkspace { show(error.localizedDescription) }
            }
        }
    }

    func closeActiveTab() {
        guard let workspace = activeWorkspace, let tab = workspace.activeTab else { return }
        close(tab, in: workspace)
    }

    func close(_ tab: EditorTab, in workspace: Workspace, confirmed: Bool = false) {
        if tab.isDirty && !confirmed {
            presentation = .confirmation(WorkbenchConfirmation(title: "放弃未保存的修改？", detail: tab.path,
                actionTitle: "放弃修改", cancelTitle: "继续编辑", destructive: true) { [weak self] in self?.close(tab, in: workspace, confirmed: true) })
            return
        }
        workspace.close(tab)
    }

    func saveActiveTab() {
        guard let workspace = activeWorkspace, let tab = workspace.activeTab, tab.draft != nil else { return }
        Task { await workspace.save(tab) }
    }

    func attach(_ file: String) {
        guard let engine, let session = active else { return }
        perform {
            let entry = try await engine.files.stat(session.config, file)
            self.addAttachments([Attachment(name: entry.name, path: entry.path, size: entry.size)], to: session.id)
        }
    }

    func addAttachments(_ files: [Attachment], to id: String) {
        var current = attachments[id] ?? []
        for file in files where !current.contains(where: { $0.path == file.path }) { current.append(file) }
        attachments[id] = current
    }

    func upload(_ urls: [URL], to directory: String? = nil) {
        guard let engine, let config = currentConfig, isConnected else { show("请先连接 SSH"); return }
        guard !urls.isEmpty else { return }
        guard urls.count <= 20 else { show("一次最多上传 20 个文件"); return }
        if active == nil {
            do {
                let session = try engine.create(config)
                drafts[session.id] = drafts.removeValue(forKey: "welcome-" + config.key)
                select(session.id)
                composerFocus = UUID()
            } catch { show(error.localizedDescription); return }
        }
        guard let session = active else { return }
        let target = directory
        guard !uploadingSessions.contains(session.id) else { show("请等待当前上传完成"); return }
        uploadingSessions.insert(session.id)
        perform {
            defer {
                self.uploadingSessions.remove(session.id)
                self.batchUploadProgress[session.id] = nil
            }
            if urls.count > 1 { self.batchUploadProgress[session.id] = "正在上传 · 0/\(urls.count) 个文件已处理" }
            let results = await engine.files.uploadBatch(session.config, files: urls, directory: target) { [weak self] completed, total in
                guard total > 1, let self else { return }
                await MainActor.run { self.batchUploadProgress[session.id] = "正在上传 · \(completed)/\(total) 个文件已处理" }
            }
            for result in results {
                let url = result.file
                if let attachment = result.attachment {
                    self.addAttachments([attachment], to: session.id)
                    self.failedUploads[session.id]?.removeAll { $0 == url }
                    self.failedUploadDirectories[session.id]?[url] = nil
                } else {
                    self.failedUploadDirectories[session.id, default: [:]][url] = target
                    if !(self.failedUploads[session.id] ?? []).contains(url) { self.failedUploads[session.id, default: []].append(url) }
                    self.show(url.lastPathComponent + ": " + (result.error ?? "上传失败"))
                }
            }
            let succeeded = results.filter { $0.attachment != nil }.count
            self.transferStatuses[session.config] = directory == nil ? "" : "上传完成 · \(succeeded)/\(urls.count) 个成功"
            await self.workspace(for: session)?.reload(force: true)
        }
    }

    func markActiveRead() {
        if let activeId { unreadSessions.remove(activeId) }
        NSApp.dockTile.badgeLabel = unreadSessions.isEmpty ? nil : String(unreadSessions.count)
    }

    private func postNotification(id: String, title: String, body: String, sessionId: String?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func testNotification() {
        guard !notificationTestRunning else { return }
        notificationTestRunning = true; notificationTestStatus = "正在发送…"
        Task {
            defer { notificationTestRunning = false }
            do {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    notificationTestStatus = "系统尚未允许通知，请先开启通知权限。"; return
                }
                let id = "remotecc-test-" + UUID().uuidString
                try await postNotification(id: id, title: "RemoteCC 通知测试", body: "任务通知已送达。", sessionId: activeId)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let delivered = await center.deliveredNotifications()
                notificationTestStatus = delivered.contains { $0.request.identifier == id } ? "已在系统通知中心确认送达" : "已提交，但未确认送达；请检查专注模式与系统通知设置。"
            } catch { notificationTestStatus = "通知测试失败：" + error.localizedDescription }
        }
    }

    func setNotifications(_ enabled: Bool) {
        let request = UUID(); notificationRequestID = request
        if !enabled {
            notificationsAuthorizing = false; notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "task-notifications")
            return
        }
        notificationsAuthorizing = true; notificationTestStatus = "正在请求系统通知权限…"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.notificationRequestID == request, self.notificationsAuthorizing else { return }
            self.notificationRequestID = UUID()
            self.notificationsAuthorizing = false
            self.notificationTestStatus = "系统通知授权未响应，请检查系统权限提示后重试。"
        }
        Task {
            defer { if notificationRequestID == request { notificationsAuthorizing = false } }
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                guard notificationRequestID == request else { return }
                notificationsEnabled = allowed
                UserDefaults.standard.set(allowed, forKey: "task-notifications")
                notificationTestStatus = allowed ? "系统通知已允许，可发送测试通知。" : "系统未允许通知，请在系统设置中允许 RemoteCC 通知。"
            } catch {
                if notificationRequestID == request { notificationTestStatus = "通知权限请求失败：" + error.localizedDescription }
            }
        }
    }

    func pickAndUpload(to directory: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, to: directory)
    }

    func pasteImage(_ data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return }
        upload([url])
    }

    func download(_ file: String) {
        guard let engine, let session = active else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (file as NSString).lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try await engine.files.download(session.config, file, to: url)
            self.show("已下载到 " + url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A private copy in the cache, so outside edits never change what the server holds.
    func openLocally(_ file: String) {
        guard let engine, let session = active else { return }
        perform {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent((file as NSString).lastPathComponent)
            try await engine.files.download(session.config, file, to: url)
            NSWorkspace.shared.open(url)
        }
    }

    func shutdown() {
        UserDefaults.standard.set(drafts.filter { !$0.value.isEmpty }, forKey: "composer-drafts")
        if let data = try? JSONEncoder().encode(attachments) {
            UserDefaults.standard.set(data, forKey: "composer-attachments")
        }
        historyPoll?.cancel()
        selectionRefresh?.cancel()
        engine?.shutdown()
        let connections = self.connections
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { await connections?.closeAll(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 3)
    }
}
#endif
