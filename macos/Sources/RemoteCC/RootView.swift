#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 240
    @State private var resizeStart: CGFloat?

    var body: some View {
        Group {
            if let failure = model.fatalError {
                ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        SidebarView().frame(width: sidebarWidth)
                            .overlay(alignment: .trailing) {
                                Color.clear.frame(width: 6).contentShape(Rectangle())
                                    .gesture(DragGesture().onChanged { value in
                                        if resizeStart == nil { resizeStart = sidebarWidth }
                                        sidebarWidth = min(300, max(210, (resizeStart ?? sidebarWidth) + value.translation.width))
                                    }.onEnded { _ in resizeStart = nil })
                                    .accessibilityLabel("调整侧栏宽度")
                                    .accessibilityAdjustableAction { direction in
                                        switch direction {
                                        case .increment: sidebarWidth = min(300, sidebarWidth + 10)
                                        case .decrement: sidebarWidth = max(210, sidebarWidth - 10)
                                        @unknown default: break
                                        }
                                    }
                            }
                    }
                    WorkArea().frame(minWidth: 340, maxWidth: .infinity)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.checkForUpdates(manual: true) }
                        } label: {
                            HStack(spacing: 6) {
                                if model.checkingForUpdates { ProgressView().controlSize(.mini) }
                                else { Image(systemName: model.availableUpdate == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill") }
                                Text(model.checkingForUpdates ? "检查中…" : model.availableUpdate.map { "更新至 " + $0 } ?? "检查更新")
                            }
                        }
                        .disabled(model.checkingForUpdates)
                        .help("当前版本 " + model.currentVersion)
                        .accessibilityLabel(model.availableUpdate == nil ? "检查更新" : "有新版本，查看更新")
                    }
                    ToolbarItem(placement: .navigation) {
                        Button { sidebarVisible.toggle() } label: {
                            Label(sidebarVisible ? "收起侧栏" : "展开侧栏", systemImage: "sidebar.left")
                        }.help(sidebarVisible ? "收起侧栏" : "展开侧栏")
                    }
                }
            }
        }
        .tint(WorkbenchTheme.accent)
        .foregroundStyle(WorkbenchTheme.ink)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(.white).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 24).frame(maxWidth: 650).textSelection(.enabled)
            }
        }
        #if DEBUG
        .sheet(isPresented: $model.showChatGallery) { ChatGallery() }
        #endif
        .sheet(isPresented: $model.showWorktree) { WorktreeSheet().workbenchPanel() }
        .sheet(isPresented: $model.showUsage) { UsageSheet().workbenchPanel() }
        .sheet(isPresented: $model.showActivity) { ActivitySheet().workbenchPanel() }
        .sheet(isPresented: $model.showConnect) { ConnectSheet().workbenchPanel() }
        .sheet(isPresented: $model.showProjectPicker) { ProjectPickerSheet().workbenchPanel() }
        .sheet(isPresented: $model.showSettings) { SettingsSheet().workbenchPanel() }
        .sheet(isPresented: $model.showPreferences) { PreferencesSheet().workbenchPanel() }
        .sheet(isPresented: $model.showQuickOpen) { QuickOpenSheet().workbenchPanel() }
        .sheet(isPresented: $model.showSessionTools) { SessionToolsSheet().workbenchPanel() }
        .sheet(item: Binding(get: { model.commandPicker.map(IdentifiedInteraction.init) }, set: { if $0 == nil { model.commandPicker = nil } })) { CommandPickerSheet(interaction: $0.value).workbenchPanel() }
    }
}

struct IdentifiedInteraction: Identifiable {
    let value: CommandInteraction
    var id: String { value.command }
}

struct WorkArea: View {
    @EnvironmentObject private var model: AppModel

    @State private var showingChat = false

    var body: some View {
        GeometryReader { geometry in
            let workspace = model.activeWorkspace
            let hasEditor = workspace?.activeTab != nil
            let hasFiles = model.showFiles && model.active != nil
            let hasWorkspace = hasEditor || hasFiles
            if geometry.size.width < 720 && hasWorkspace {
                VStack(spacing: 0) {
                    Picker("显示区域", selection: $showingChat) {
                        Text("对话").tag(true)
                        Text("工作区").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().padding(10)
                    if showingChat { ChatView() }
                    else { workspacePane(workspace, hasFiles: hasFiles) }
                }
            } else {
                HSplitView {
                    ChatView().frame(minWidth: 340, maxWidth: .infinity)
                    if hasWorkspace {
                        if geometry.size.width >= 1080 {
                            if let workspace, hasEditor { EditorPane(workspace: workspace).frame(minWidth: 360, maxWidth: .infinity) }
                            if hasFiles { FilePanel().frame(minWidth: 230, idealWidth: 260, maxWidth: 340) }
                        } else {
                            workspacePane(workspace, hasFiles: hasFiles).frame(minWidth: 320, maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .onChange(of: model.activeWorkspace?.activeTabId) { showingChat = false }
        .onChange(of: model.showFiles) { if model.showFiles { showingChat = false } }
        .navigationTitle(model.active?.name ?? "claude-mirror")
        .navigationSubtitle(model.active.map { ($0.directory as NSString).lastPathComponent + " · " + $0.host } ?? model.currentConfig?.displayName ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let session = model.active {
                    Button { model.openProjectPicker() } label: {
                        Label((session.directory as NSString).lastPathComponent, systemImage: "folder")
                    }.labelStyle(.titleAndIcon).help("切换项目").disabled(!model.isConnected)
                    if session.isBusy || !model.isConnected {
                        Text(model.isConnected ? statusLabel(session.status) : "未连接")
                            .font(.caption).foregroundStyle(.secondary).help(session.transportError ?? "")
                    }
                    Menu {
                        Button("对话选项", systemImage: "slider.horizontal.3") { model.showPreferences = true }
                        Button("同步消息", systemImage: "arrow.clockwise") { Task { await model.refreshVisibleHistory(session.id) } }
                            .disabled(!model.isConnected || session.isBusy || session.remoteOwner != nil || model.refreshingHistory.contains(session.id))
                        Button("订阅用量 /usage", systemImage: "chart.bar") { model.runRemoteCommand("usage") }
                            .disabled(!model.isConnected || session.isBusy)
                        Button("对话用量与上下文", systemImage: "gauge.with.dots.needle.33percent") { model.showUsage = true }
                        Button("分支对话", systemImage: "arrow.triangle.branch") {
                            model.perform { if let fork = try model.engine?.fork(session.id) { model.select(fork.id) } }
                        }
                        Button("导出对话", systemImage: "square.and.arrow.up") { model.exportConversation(session) }
                        Button("会话工具", systemImage: "slider.horizontal.3") { model.showSessionTools = true }
                    } label: { Label("对话操作", systemImage: "ellipsis") }
                    Button { model.showFiles.toggle() } label: { Label("文件", systemImage: "sidebar.right") }
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }
    @ViewBuilder private func workspacePane(_ workspace: Workspace?, hasFiles: Bool) -> some View {
        if let workspace, workspace.activeTab != nil {
            if hasFiles {
                VSplitView {
                    FilePanel().frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
                    EditorPane(workspace: workspace).frame(minHeight: 200, maxHeight: .infinity)
                }
            } else { EditorPane(workspace: workspace) }
        } else if hasFiles { FilePanel() }
    }

}

func statusLabel(_ status: String) -> String {
    ["detached": "远端任务待同步", "idle": "就绪", "connecting": "连接中", "working": "正在回复", "permission": "等待你的确认", "stopping": "正在停止", "stopped": "已停止", "error": "调用未完成"][status] ?? status
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAllProjects = false
    @State private var searchExpanded = false
    @State private var recentExpanded = false
    @FocusState private var searchFocused: Bool

    private var groups: [(key: String, sessions: [ChatSession])] {
        let filter = model.searchText.lowercased()
        let visible = model.machineSessions.filter { ($0.archived ?? false) == model.showArchived }.filter {
            filter.isEmpty || "\($0.name) \($0.host) \($0.directory) \($0.historySummary ?? "")".lowercased().contains(filter)
        }
        var order: [String] = [], grouped: [String: [ChatSession]] = [:]
        for session in visible {
            if grouped[session.projectKey] == nil { order.append(session.projectKey) }
            grouped[session.projectKey, default: []].append(session)
        }
        return order.map { ($0, grouped[$0]!) }.filter { !model.projectMissing($0.1[0]) }
    }

    private var unavailableSessions: [ChatSession] {
        model.machineSessions.filter {
            model.projectMissing($0) && ($0.archived ?? false) == model.showArchived &&
            (model.searchText.isEmpty || ($0.name + " " + $0.directory).localizedCaseInsensitiveContains(model.searchText))
        }
    }

    private var visibleGroups: [(key: String, sessions: [ChatSession])] {
        if showAllProjects || !model.searchText.isEmpty { return groups }
        var result = Array(groups.prefix(6))
        if let active = groups.first(where: { $0.sessions.contains(where: { $0.id == model.activeId }) }), !result.contains(where: { $0.key == active.key }) { result.append(active) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("claude-mirror").font(.system(size: 15, weight: .semibold)).tracking(-0.5)
                    Spacer()
                }.padding(.horizontal, 7).padding(.bottom, 2)
                HStack(spacing: 4) {
                    MachineSwitcher()
                    Spacer()
                    Button { model.showActivity = true } label: {
                        Image(systemName: "bell")
                            .overlay(alignment: .topTrailing) {
                                if !model.attentionSessions.isEmpty { Circle().fill(WorkbenchTheme.accent).frame(width: 5, height: 5).offset(x: 3, y: -2) }
                            }
                    }.buttonStyle(QuietButtonStyle()).help("所有机器的任务").accessibilityLabel("所有机器的任务")
                    Button {
                        if searchExpanded { closeSearch() }
                        else { searchExpanded = true; searchFocused = true }
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(QuietButtonStyle()).help("搜索对话")
                        .accessibilityLabel("搜索对话")
                }
                HStack(spacing: 4) {
                    Button { model.newConversation() } label: {
                        HStack {
                            Label("新建对话", systemImage: "square.and.pencil")
                            Spacer()
                            Text("⌘ N").font(.caption).opacity(0.65)
                        }
                    }
                    .buttonStyle(QuietButtonStyle()).help("新对话（⌘N）").disabled(model.currentConfig == nil)
                    HistorySyncButton()
                }
                if searchExpanded {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索对话", text: $model.searchText)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .onAppear { searchFocused = true }
                            .onExitCommand { closeSearch() }
                        Button { closeSearch() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("关闭搜索").accessibilityLabel("关闭搜索")
                    }
                    .font(.callout).padding(9)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                if !groups.isEmpty {
                    Section(model.showArchived ? "已归档 · 项目" : "项目") {
                        ForEach(Array(visibleGroups.enumerated()), id: \.element.key) { index, group in
                            ProjectGroup(sessions: group.sessions, searching: !model.searchText.isEmpty, initiallyExpanded: index < 2)
                        }
                        if model.searchText.isEmpty && (showAllProjects || groups.count > visibleGroups.count) {
                            Button(showAllProjects ? "收起项目" : "更多项目（\(groups.count - visibleGroups.count)）") { showAllProjects.toggle() }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.callout)
                                .padding(.vertical, 6).listRowSeparator(.hidden).selectionDisabled()
                        }
                    }
                    if model.searchText.isEmpty && !model.showArchived {
                        Section {
                        DisclosureGroup("最近对话", isExpanded: $recentExpanded) {
                            ProjectGroup(sessions: Array(model.machineSessions.filter { $0.archived != true && !model.projectMissing($0) }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8)), searching: false, flat: true)
                        }.listRowSeparator(.hidden)
                        }
                    }
                }
                if !unavailableSessions.isEmpty {
                    Section("目录已移除 · 历史对话") {
                        ProjectGroup(sessions: unavailableSessions, searching: !model.searchText.isEmpty, flat: true)
                    }
                }
                }.padding(.horizontal, 10).padding(.vertical, 8)

            }
            .id(model.currentConfig?.key ?? "no-machine")
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if groups.isEmpty && unavailableSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.searchText.isEmpty ? (model.showArchived ? "还没有归档的对话" : "暂无历史对话") : "没有找到匹配的对话")
                        Text(model.searchText.isEmpty ? "连接后自动同步这台机器的对话" : "试试其他关键词")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 20).allowsHitTesting(false)
                }
            }
            ServerFooter()
        }
        .foregroundStyle(WorkbenchTheme.sidebarInk)
        .background(WorkbenchTheme.sidebar)
    }

    private func closeSearch() {
        model.searchText = ""
        searchExpanded = false
        searchFocused = false
    }


}

struct ProjectGroup: View {
    @EnvironmentObject private var model: AppModel
    let sessions: [ChatSession]
    let searching: Bool
    var flat = false
    var initiallyExpanded = false
    @State private var headerHovered = false
    @State private var showAll = false
    @State private var expanded: Bool?
    @State private var renaming: ChatSession?
    @State private var name = ""

    private var isExpanded: Binding<Bool> {
        Binding(get: { searching || (expanded ?? (initiallyExpanded || sessions.contains { $0.id == model.activeId })) }, set: { expanded = $0 })
    }

    private var visibleSessions: [ChatSession] {
        if flat || searching || showAll { return sessions }
        var result = Array(sessions.prefix(5))
        if let active = sessions.first(where: { $0.id == model.activeId }), !result.contains(where: { $0.id == active.id }) { result.append(active) }
        return result
    }

    private var rows: some View {
            ForEach(visibleSessions) { session in
                Button { model.select(session.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if session.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text(historyDisplayTitle(session.name)).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.unreadSessions.contains(session.id) { Circle().fill(WorkbenchTheme.accent).frame(width: 6, height: 6) }
                    }
                    if session.isBusy {
                        Text(statusLabel(session.status)).font(.caption2).foregroundStyle(WorkbenchTheme.accent)
                    }
                }
                }
                .buttonStyle(SidebarNavigationStyle(selected: model.activeId == session.id))
                .accessibilityAddTraits(model.activeId == session.id ? .isSelected : [])
                .help(session.directory + " · " + session.name)
                .contextMenu {
                    Button("重命名…") { name = session.name; renaming = session }
                    Button(session.pinned == true ? "取消固定" : "固定") { model.perform { try model.engine?.setPinned(session.id, session.pinned != true) } }
                    Button(session.archived == true ? "恢复" : "归档") { model.perform { try model.engine?.setArchived(session.id, session.archived != true) } }
                    Button("导出…") { model.exportConversation(session) }
                    Divider()
                    Button("删除…", role: .destructive) { model.deleteConversation(session) }
                }
            }
    }

    @ViewBuilder private func projectActions(_ first: ChatSession) -> some View {
        Text(first.host + " · " + first.directory)
        Button("在项目中新建对话") { model.newConversation(in: first) }.disabled(model.projectMissing(first))
        Button("浏览远端文件夹") {
            model.select(first.id); model.panel = .files; model.showFiles = true
            Task { await model.activeWorkspace?.browse(first.directory) }
        }
        Button("新建隔离工作区…") { model.select(first.id); model.showWorktree = true }
            .disabled(model.projectMissing(first) || !model.isConnected)
        Button("删除远端聊天记录…", role: .destructive) { model.deleteProjectHistory(first) }
            .disabled(!model.isConnected)
        Button("复制文件夹路径") { copyToPasteboard(first.directory) }
        Divider()
        Button(model.showArchived ? "恢复项目" : "从侧栏移除项目…") { model.archiveProject(first, archived: !model.showArchived) }
    }

    var body: some View {
        Group {
            if flat { rows }
            else if let first = sessions.first {
                DisclosureGroup(isExpanded: isExpanded) {
                    rows.padding(.leading, 24)
                    if !searching && (showAll || sessions.count > visibleSessions.count) {
                        Button(showAll ? "收起" : "显示更多（\(sessions.count - visibleSessions.count)）") { showAll.toggle() }
                            .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 6).listRowSeparator(.hidden).selectionDisabled()
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(first.directory == "/" ? "/" : (first.directory as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Button { model.newConversation(in: first) } label: {
                            Image(systemName: "plus").frame(width: 20, height: 20)
                        }.buttonStyle(.plain).help("在此项目中新建对话")
                            .accessibilityLabel("在此项目中新建对话")
                            .disabled(model.projectMissing(first))
                            .opacity(headerHovered ? 1 : 0).allowsHitTesting(headerHovered)
                        Menu { projectActions(first) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("项目操作").accessibilityLabel("项目操作")
                            .opacity(headerHovered ? 1 : 0)
                            .allowsHitTesting(headerHovered)
                    }.contentShape(Rectangle()).onHover { headerHovered = $0 }.help(first.host + " · " + first.directory)
                        .contextMenu { projectActions(first) }
                }
            }
        }
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .onChange(of: model.activeId) {
            if sessions.contains(where: { $0.id == model.activeId }) { expanded = true }
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("对话名称", text: $name)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let session = renaming { model.perform { try model.engine?.rename(session.id, name) } }
                renaming = nil
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).count > 80)
        } message: { Text("输入 1–80 个字符的名称。") }
    }
}

struct MachineSwitcher: View {
    @EnvironmentObject private var model: AppModel
    @State private var choosing = false
    var body: some View {
        Button { choosing.toggle() } label: {
            // Keep the current host visible beside its connection status.
            HStack(spacing: 7) {
                Circle().fill(model.isConnected ? WorkbenchTheme.sage : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(model.currentConfig?.displayName ?? "选择机器").font(.headline).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).help("当前机器：" + (model.currentConfig?.displayName ?? "未连接") + " · 切换或添加机器")
        .popover(isPresented: $choosing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Button { choosing = false; model.activeId = nil } label: { Label("返回首页", systemImage: "house") }.buttonStyle(QuietButtonStyle())
                Divider()
                Text("我的机器").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(8)
                ForEach(model.savedMachines, id: \.key) { machine in
                    Button {
                        choosing = false
                        model.selectMachine(machine)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(machine.displayName)
                                Text(machine.host + (machine.port.map { ":\($0)" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.currentConfig?.key == machine.key { Image(systemName: "checkmark") }
                            Circle().fill(model.engine?.connectionState(machine).status == .connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        }.font(.body).padding(4).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle())
                    .contextMenu {
                        Button("重命名…") {
                            let alert = NSAlert()
                            alert.messageText = "主机名称"
                            let field = NSTextField(string: machine.displayName)
                            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                            alert.accessoryView = field
                            alert.addButton(withTitle: "保存")
                            alert.addButton(withTitle: "取消")
                            if alert.runModal() == .alertFirstButtonReturn { model.renameMachine(machine, name: field.stringValue) }
                        }
                        Divider()
                        Toggle("允许此服务器反向连接本机", isOn: Binding(
                            get: { machine.reverseAccess == true },
                            set: { model.setReverseAccess(machine, enabled: $0) }))
                        if machine.reverseAccess == true {
                            Text(model.reverseStatus(machine))
                            Button("复制反向连接命令") { model.copyReverseCommand(machine) }
                                .disabled(model.reverseStates[machine.key]?.command == nil)
                        }
                    }
                }
                Divider()
                if let machine = model.currentConfig {
                    Toggle("反向访问本机", isOn: Binding(
                        get: { model.currentConfig?.reverseAccess == true },
                        set: { model.setReverseAccess(machine, enabled: $0) }))
                        .font(.callout).padding(.horizontal, 8)
                    Text("允许服务器以你的用户身份访问这台 Mac。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    if machine.reverseAccess == true {
                        Text(model.reverseStatus(machine)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        Button("复制连接命令") { model.copyReverseCommand(machine) }
                            .disabled(model.reverseStates[machine.key]?.command == nil).padding(.horizontal, 8)
                    }
                    Divider()
                }
                Button { choosing = false; model.showConnect = true } label: {
                    Label("添加机器…", systemImage: "plus").font(.body).padding(10)
                }.buttonStyle(.plain)
            }.padding(8).frame(width: 260).workbenchPanel()
        }
    }
}

struct HistorySyncButton: View {
    @EnvironmentObject private var model: AppModel

    private var syncing: Bool {
        guard let config = model.currentConfig else { return false }
        return model.syncingMachines.contains(config.key)
    }

    var body: some View {
        Button {
            if let config = model.currentConfig { Task { await model.discoverHistory(config) } }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(syncing ? 0 : 1)
                if syncing { ProgressView().controlSize(.mini) }
            }.frame(width: 16, height: 16)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!model.isConnected || syncing)
        .accessibilityLabel(syncing ? "正在同步会话" : "同步会话")
        .help("同步会话 · " + (model.connectionState.error.isEmpty ? model.historyStatus : model.connectionState.error))
    }
}

struct ServerFooter: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 2) {
            Button { model.showArchived.toggle() } label: {
                Label(model.showArchived ? "全部对话" : "归档", systemImage: "archivebox")
            }.buttonStyle(SidebarNavigationStyle(selected: model.showArchived))
            Button { model.showSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }.buttonStyle(SidebarNavigationStyle())
        }.padding(.horizontal, 10).padding(.bottom, 8)
    }
}

struct ConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var name = ""
    @State private var username = ""
    @State private var identityFile = ""
    @State private var password = ""
    @State private var authentication = SSHAuthentication.automatic
    @State private var reverseAccess = false
    @State private var error = ""
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("添加机器").font(.title2.weight(.semibold))
                Text("通过 SSH 连接远端 Claude Code。")
                    .font(.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                connectionField("主机名称", text: $name, prompt: "例如：开发服务器（可选）")
                connectionField("SSH 主机", text: $host, prompt: "IP、域名、SSH 别名或 user@host")
                HStack {
                    connectionField("用户名", text: $username, prompt: "留空使用 SSH 配置")
                    connectionField("端口", text: $port, prompt: "默认使用 SSH 配置")
                }
                Picker("认证方式", selection: $authentication) {
                    Text("SSH 配置 / Agent").tag(SSHAuthentication.automatic)
                    Text("密码").tag(SSHAuthentication.password)
                    Text("私钥文件").tag(SSHAuthentication.keyFile)
                }
                if authentication == .password {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("密码").font(.callout.weight(.medium))
                        SecureField("服务器密码", text: $password)
                            .textFieldStyle(.plain).font(.body).padding(12)
                            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
                    }
                }
                if authentication == .keyFile {
                    HStack {
                        Text(identityFile.isEmpty ? "尚未选择私钥" : identityFile)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("选择私钥…") {
                            let panel = NSOpenPanel()
                            panel.showsHiddenFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
                        }
                    }
                }
            }
            Toggle("允许此服务器反向连接本机", isOn: $reverseAccess)
                .font(.callout)
                .help("复用本应用的 SSH 连接，让服务器通过私有 socket 连到本机的远程登录服务。服务器会获得一把只能经此通道使用的专用密钥，关闭后立即撤销；开启期间服务器上的程序能以你的身份登录这台 Mac。")
            Text("密码仅用于本次连接。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if connecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WorkbenchButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(connecting)
                Button(connecting ? "连接并同步中…" : "连接机器") { connect() }
                    .buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(connecting || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 460).background(WorkbenchTheme.canvas)
        .interactiveDismissDisabled(connecting)
        .onChange(of: authentication) { _, _ in password = "" }
        .onDisappear { password = "" }
    }

    private func connectionField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout.weight(.medium))
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.plain)
                .font(.body).padding(12)
                .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
        }
    }

    private func connect() {
        connecting = true; error = ""
        Task {
            do {
                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard user.isEmpty || !host.contains("@") else { throw RemoteError("主机地址已包含用户名，请清空单独的用户名字段") }
                guard user.isEmpty || (!user.contains("@") && !user.contains(":")) else { throw RemoteError("用户名不能包含 @ 或冒号") }
                let destination = user.isEmpty ? host : user + "@" + host.trimmingCharacters(in: .whitespacesAndNewlines)
                let config = ConnectionConfig(host: destination, port: try ConnectionConfig.parsePort(port), directory: "~",
                                              name: name, identityFile: authentication == .keyFile ? identityFile : nil, authentication: authentication,
                                              reverseAccess: reverseAccess ? true : nil)
                let credential = authentication == .password && !password.isEmpty ? password : nil
                password = ""
                try await model.connect(config, password: credential)
                dismiss()
            } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}
#endif
