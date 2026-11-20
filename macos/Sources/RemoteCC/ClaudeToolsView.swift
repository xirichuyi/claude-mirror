#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

/// Project/session controls use the resident owner, never a disposable inspector for mutations.
struct ClaudeToolsView: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    let sessionID: String
    let section: SessionToolSection
    @StateObject private var state = SessionToolsStore()
    private var content: JSON? { state.content }
    private var runtime: JSON? { state.runtime }
    @State private var search = ""
    private var busy: Bool { state.busy }
    private var message: String? { state.message }
    @State private var revision = 0

    private var session: ChatSession? { model.engine?.session(sessionID) }
    private var actions: [String] { runtime?["actions"]?.array?.compactMap(\.string) ?? [] }
    private var canManage: Bool { session?.remoteOwner != nil && !busy && model.isConnected }
    private var items: [JSON] {
        let values = section == .mcp ? runtime?["servers"]?.array ?? [] : content?.array ?? content?["plugins"]?.array ?? []
        return values.filter { search.isEmpty || $0.text().localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索名称或说明", text: $search).textFieldStyle(WorkbenchTextFieldStyle())
                Button { revision += 1 } label: {
                    ZStack {
                        WorkbenchIcon(symbol: "arrow.clockwise").opacity(busy ? 0 : 1)
                        if busy { ProgressView().controlSize(.small) }
                    }
                }.buttonStyle(WorkbenchIconButtonStyle()).help("刷新").accessibilityLabel("刷新")
                    .disabled(busy || !model.isConnected)
            }
            if let message { Text(message).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if section == .config { configuration }
                    else if section == .status {
                        if let session {
                            LabeledContent("项目", value: session.directory)
                            LabeledContent("模型", value: session.model ?? "远端默认")
                            LabeledContent("状态", value: statusLabel(session.status))
                            LabeledContent("权限", value: session.preferences?.permissionMode ?? "default")
                            LabeledContent("思考强度", value: session.preferences?.effort ?? "默认")
                            if let id = session.remoteSessionId { LabeledContent("会话 ID", value: id).textSelection(.enabled) }
                            HStack {
                                Button("模型与权限") { dismiss(); model.showPreferences = true }
                                Button("上下文与用量") { dismiss(); model.showUsage = true }
                                Button("隔离工作树") { dismiss(); model.showWorktree = true }
                            }
                        }
                    } else {
                        if section == .skills || section == .plugins { reloadButton }
                        if items.isEmpty && !busy && message == nil {
                            InterfaceState(title: search.isEmpty ? "暂无相关项目" : "没有匹配结果", detail: "", symbol: "square.stack")
                        }
                        ForEach(items, id: \.self) { item in itemView(item) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }
        .task(id: "\(sessionID):\(section.rawValue):\(revision):\(model.isConnected)") { await load() }
        .onDisappear { state.invalidate() }
    }

    @ViewBuilder private var reloadButton: some View {
        let action = section == .skills ? "reloadSkills" : "reloadPlugins"
        Button(section == .skills ? "从磁盘重载技能" : "重新加载插件") { manage(action) }
            .disabled(!canManage || !actions.contains(action))
    }

    private func itemTitle(_ item: JSON) -> String {
        for key in ["displayName", "name", "title", "description", "id"] {
            if let value = item[key]?.string { return value }
        }
        return item.string ?? "项目"
    }

    private func itemView(_ item: JSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(itemTitle(item))
                    .font(.subheadline.weight(.semibold)).textSelection(.enabled)
                Spacer()
                if let status = item["status"]?.string { Text(status).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
            }
            if let description = item["description"]?.string { Text(description).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(3).help(description).textSelection(.enabled) }
            if let error = item["error"]?.string { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.warning).textSelection(.enabled) }
            if section == .commands || section == .skills, let name = item["name"]?.string {
                HStack {
                    Text("/" + name + (item["argumentHint"]?.string.map { " " + $0 } ?? "")).font(.caption.monospaced())
                    Spacer()
                    Button("填入输入框") { insertCommand(name) }.disabled(!(model.drafts[sessionID] ?? "").isEmpty)
                        .help("保留已有草稿；填入后由你确认发送")
                }
            }
            if section == .mcp, let name = item["name"]?.string {
                HStack {
                    Button("重新连接") { manage("reconnectMcp", name: name) }.disabled(!canManage || !actions.contains("reconnectMcp"))
                    let enabled = item["status"]?.string != "disabled"
                    Button(enabled ? "禁用" : "启用") { manage("toggleMcp", name: name, enabled: !enabled) }
                        .disabled(!canManage || !actions.contains("toggleMcp"))
                    Text("仅当前会话").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
            }
            if section == .tasks, item["status"]?.string == "running", let id = item["id"]?.string {
                Button("停止任务") { stopTask(id) }.disabled(busy || !model.isConnected)
            }
            DisclosureGroup("详细信息") { CodeBlock(text: item.text(pretty: true)) }
        }.padding(.vertical, 10).padding(.horizontal, 8)
            .overlay(alignment: .bottom) { WorkbenchTheme.separator.frame(height: 1) }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑远端 Claude Code 实际使用的文件，保存沿用编辑器的冲突检查。文件不存在时会明确提示。")
                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            ForEach([("项目记忆", "CLAUDE.md"), ("项目本地记忆", "CLAUDE.local.md"),
                     ("用户记忆", "~/.claude/CLAUDE.md"), ("项目设置 / 权限 / Hooks", ".claude/settings.json"),
                     ("项目本地设置", ".claude/settings.local.json"), ("用户设置 / 权限 / Hooks", "~/.claude/settings.json"),
                     ("项目 MCP 配置", ".mcp.json")], id: \.1) { title, path in
                Button(title) { dismiss(); model.open(path) }.buttonStyle(.link)
            }
            Text("Hooks、权限和 MCP 配置的生效时机由远端 Claude 决定；需要时重新建立会话。")
                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            Button("重载输出样式") { manage("reloadOutputStyles") }
                .disabled(!canManage || !actions.contains("reloadOutputStyles"))
            Link("Claude Code 官方功能说明", destination: URL(string: "https://code.claude.com/docs/en/desktop")!)
        }
    }

    private func stopTask(_ id: String) {
        guard let engine = model.engine else { return }
        state.perform {
            try await engine.stopBackgroundTask(sessionID, task: id)
            return (try await engine.details(sessionID, section: "tasks"), nil, "已发送停止请求")
        }
    }

    private func insertCommand(_ name: String) {
        guard (model.drafts[sessionID] ?? "").isEmpty else { return }
        model.drafts[sessionID] = "/" + name + " "
        model.composerFocus = UUID()
        dismiss()
    }

    private func manage(_ action: String, name: String? = nil, enabled: Bool? = nil) {
        guard canManage, let engine = model.engine else { return }
        let requestedSection = section
        state.perform {
            let result = try await engine.manageRuntime(sessionID, action: action, name: name, enabled: enabled)
            let runtime = try await engine.details(sessionID, section: "runtimeStatus")
            let content = requestedSection == .mcp ? runtime : try await engine.details(sessionID, section: requestedSection.rawValue)
            let message = result["held"]?.isTruthy == true ? "插件重载已暂缓：远端检测到会影响当前提示缓存。" : "远端操作已完成"
            return (content, runtime, message)
        }
    }

    @MainActor private func load() async {
        guard model.isConnected, let engine = model.engine else { state.invalidate(); return }
        await state.load(section: section) { try await engine.details(sessionID, section: $0) }
    }
}
#endif
