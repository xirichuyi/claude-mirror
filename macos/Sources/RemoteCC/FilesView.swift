#if canImport(SwiftUI)
import SwiftUI
import AppKit
import PDFKit
import RemoteCCCore

func gitColor(_ code: String?) -> Color {
    switch code {
    case "M", "R": return WorkbenchTheme.modified
    case "A", "?": return WorkbenchTheme.added
    case "D": return WorkbenchTheme.removed
    case "U": return WorkbenchTheme.error
    default: return WorkbenchTheme.ink
    }
}

func byteText(_ bytes: Int) -> String {
    bytes < 1024 ? "\(bytes) B" : bytes < 1_048_576 ? String(format: "%.1f KB", Double(bytes) / 1024) : String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

struct FilePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let workspace = model.activeWorkspace {
                if !model.isConnected {
                    Label("连接已断开", systemImage: "network.slash")
                        .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(8)
                }
                RetainedPaneLayout(selection: model.panel == .files ? 0 : model.panel == .changes ? 1 : 2, parkInactive: false) {
                    FileTreeView(workspace: workspace).sidebarPaneVisible(model.showFiles && model.panel == .files)
                    VStack(spacing: 0) {
                        workspacePath(workspace)
                        ChangesView(workspace: workspace)
                    }.sidebarPaneVisible(model.showFiles && model.panel == .changes)
                    VStack(spacing: 0) {
                        workspacePath(workspace)
                        SearchView(workspace: workspace, state: model.searchState(for: workspace))
                    }.sidebarPaneVisible(model.showFiles && model.panel == .search)
                }.clipped().id(ObjectIdentifier(workspace)).disabled(!model.isConnected)
            } else {
                ContentUnavailableView(model.isConnected ? "选择项目对话" : "未连接 SSH",
                    systemImage: model.isConnected ? "folder" : "network.slash")
                    .frame(maxHeight: .infinity)
            }
        }.background { FrostedBackground() }
    }

    private func workspacePath(_ workspace: Workspace) -> some View {
        Text(workspace.root ?? model.active?.directory ?? "")
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).frame(height: 28)
    }
}

/// 24 pt rows indented 16 pt per level: chevron, file mark, name, Git letter.
struct FileTreeRow: View {
    let row: TreeRow
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        let entry = row.entry
        let tint = entry.broken == true ? WorkbenchTheme.inkDim : gitColor(row.gitCode)
        HStack(spacing: 4) {
            WorkbenchIcon(symbol: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkMuted)
                .rotationEffect(.degrees(row.expanded ? 90 : 0))
                .frame(width: 12).opacity(entry.directory ? 1 : 0)
            FileIcon(name: entry.name, directory: entry.directory, expanded: row.expanded)
            Text(entry.name + (entry.symlink == true ? " ↗" : ""))
                .font(.system(size: 13, weight: row.touched ? .semibold : .regular))
                .foregroundStyle(tint)
                .strikethrough(entry.broken == true)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if row.loading { ProgressView().controlSize(.mini).frame(width: 12).accessibilityLabel("读取目录") }
            if let code = row.gitCode {
                Text(code == "?" ? "U" : code).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16 + 4).padding(.trailing, 8)
        .frame(height: 24)
        .background(selected ? WorkbenchTheme.selected : hovered ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NamePrompt: Identifiable {
    enum Action { case newFile(String), newFolder(String), rename(FileEntry) }
    let id = UUID()
    let title: String
    let initial: String
    let action: Action
}

struct FileTreeView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    @State private var path = ""
    @State private var editingPath = false
    @FocusState private var pathFocused: Bool
    @FocusState private var treeFocused: Bool
    @State private var selectedPath: String?
    @State private var revealRequest = UUID()
    @State private var lastReveal: String?

    private var visible: Bool { model.showFiles && model.sidebarVisible && model.panel == .files }

    private var prompt: NamePrompt? {
        get { if case .fileName(let value, _) = model.presentation { return value }; return nil }
        nonmutating set { if let newValue { model.presentation = .fileName(newValue, workspace) } }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rootName: String {
        guard let root = workspace.root else { return "工作区" }
        return root == "/" ? "/" : (root as NSString).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            projectRow
            fileActions
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).padding(.horizontal, 12).padding(.bottom, 4).textSelection(.enabled) }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(workspace.rows) { row in
                        rowView(row).id(row.id)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            .focusable().focused($treeFocused).focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.rightArrow) { expandSelection(); return .handled }
            .onKeyPress(.leftArrow) { collapseSelection(); return .handled }
            .onKeyPress(.return) { openSelection(); return .handled }
            .onKeyPress(.escape) { treeFocused = false; model.focusWorkspace(); return .handled }
            .onChange(of: selectedPath) { if let selectedPath { proxy.scrollTo(selectedPath) } }
            .onChange(of: model.sidebarFocus) { if visible { focusTree() } }
            .onChange(of: visible) { if visible { focusTree() } else { treeFocused = false } }
            .overlay { if workspace.rows.isEmpty && workspace.error == nil && workspace.root != nil { InterfaceState(title: "空目录", detail: "", symbol: "folder") } }
                .task(id: "\(model.showFiles && model.sidebarVisible && model.panel == .files):\(workspace.root ?? ""):\(workspace.activeTabId ?? ""):\(revealRequest)") {
                    guard model.showFiles, model.sidebarVisible, model.panel == .files else { return }
                    let request = "\(workspace.root ?? ""):\(workspace.activeTabId ?? ""):\(revealRequest)"
                    guard lastReveal != request else { return }
                    if let path = await workspace.revealActiveFile() {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        lastReveal = request
                        selectedPath = path
                        proxy.scrollTo(path, anchor: .center)
                    }
                }
            }
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            Text(workspace.footer).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 26)
        }
        .onAppear { path = workspace.root ?? model.active?.directory ?? "~" }
        .onChange(of: workspace.root) { if let root = workspace.root { path = root }; selectedPath = workspace.rows.first?.id }
    }

    private func focusTree() {
        guard !editingPath, model.presentation == nil else { return }
        if selectedPath == nil { selectedPath = workspace.activeTab?.path ?? workspace.rows.first?.id }
        treeFocused = true
    }

    private func moveSelection(_ offset: Int) {
        let rows = workspace.rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selectedPath } ?? (offset > 0 ? -1 : rows.count)
        selectedPath = rows[min(rows.count - 1, max(0, index + offset))].id
    }

    private var selectedRow: TreeRow? { workspace.rows.first { $0.id == selectedPath } }

    private func expandSelection() {
        guard let row = selectedRow, row.entry.directory else { return }
        if row.expanded { moveSelection(1) }
        else { Task { await workspace.toggle(row.id) } }
    }

    private func collapseSelection() {
        guard let row = selectedRow else { return }
        if row.expanded { Task { await workspace.toggle(row.id) } }
        else {
            let parent = (row.id as NSString).deletingLastPathComponent
            if workspace.rows.contains(where: { $0.id == parent }) { selectedPath = parent }
        }
    }

    private func openSelection() {
        guard let row = selectedRow else { return }
        if row.entry.directory { Task { await workspace.toggle(row.id) } }
        else { treeFocused = false; model.open(row.id) }
    }

    /// The project name with its menu and quick actions, as in the reference sidebar.
    private var projectRow: some View {
        HStack(spacing: 2) {
            if editingPath {
                TextField("远端目录", text: $path).textFieldStyle(WorkbenchTextFieldStyle()).font(.system(size: 11.5, design: .monospaced))
                    .focused($pathFocused)
                    .onSubmit { editingPath = false; Task { await workspace.browse(path) } }
                    .onExitCommand { editingPath = false }
                    .onAppear { pathFocused = true }
            } else {
                WorkbenchMenu {
                    Button("前往目录…") { path = workspace.root ?? path; editingPath = true }
                    Button("上一级目录") { Task { await workspace.goToParent() } }.disabled(workspace.root == nil || workspace.root == "/")
                    Divider()
                    Button("设为工作目录") { useFolder() }.disabled(workspace.root == nil)
                    Toggle("显示隐藏文件", isOn: Binding(get: { workspace.showHidden }, set: { workspace.showHidden = $0 }))
                    if let root = workspace.root { Divider(); Button("复制路径") { copyToPasteboard(root) } }
                } label: {
                    HStack(spacing: 6) {
                        Text(String(rootName.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(WorkbenchTheme.primaryButton, in: RoundedRectangle(cornerRadius: 4))
                        Text(rootName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        WorkbenchIcon(symbol: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkMuted)
                    }
                }
                // The button style keeps the custom label; a borderless menu would drop it.
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(workspace.root ?? "").accessibilityLabel("目录：" + rootName)


            }
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 32)
    }

    private var fileActions: some View {
        HStack(spacing: 2) {
                Button {
                    if let root = workspace.root { prompt = NamePrompt(title: "新文件名称", initial: "", action: .newFile(root)) }
                } label: { WorkbenchIcon(symbol: "doc.badge.plus") }
                    .buttonStyle(WorkbenchIconButtonStyle()).help("新建文件").accessibilityLabel("新建文件").disabled(workspace.root == nil)
                Button {
                    if let root = workspace.root { prompt = NamePrompt(title: "新文件夹名称", initial: "", action: .newFolder(root)) }
                } label: { WorkbenchIcon(symbol: "folder.badge.plus") }
                    .buttonStyle(WorkbenchIconButtonStyle()).help("新建文件夹").accessibilityLabel("新建文件夹").disabled(workspace.root == nil)
                Button { Task { await workspace.reload(force: true) } } label: {
                    WorkbenchIcon(symbol: "arrow.clockwise")
                }.buttonStyle(WorkbenchIconButtonStyle()).help("刷新文件").accessibilityLabel("刷新文件").disabled(workspace.root == nil)
                Button { Task { await workspace.collapseAll(); selectedPath = workspace.rows.first?.id } } label: {
                    WorkbenchIcon(symbol: "rectangle.compress.vertical")
                }.buttonStyle(WorkbenchIconButtonStyle()).help("全部折叠").accessibilityLabel("全部折叠")
                Button { revealRequest = UUID() } label: {
                    WorkbenchIcon(symbol: "scope")
                }.buttonStyle(WorkbenchIconButtonStyle()).help("定位当前文件").accessibilityLabel("定位当前文件")
                    .disabled(workspace.activeTab == nil)
                Spacer(minLength: 0)
                WorkbenchMenu(iconOnly: true) {
                    Button("上传文件", systemImage: "square.and.arrow.up") { model.pickAndUpload(to: workspace.root) }
                } label: { WorkbenchIcon(symbol: "ellipsis") }
                .buttonStyle(WorkbenchIconButtonStyle()).accessibilityLabel("目录操作").help("更多文件操作")
                .disabled(workspace.root == nil)
        }
        .foregroundStyle(WorkbenchTheme.inkMuted)
        .padding(.horizontal, 8).frame(height: 28)
        .disabled(workspace.root == nil || !model.isConnected)
    }

    private func rowView(_ row: TreeRow) -> some View {
        FileTreeRow(row: row, selected: treeFocused ? selectedPath == row.id : workspace.activeTab.map { !$0.isDiff && $0.path == row.entry.path } ?? false)
            .help(row.entry.path)
            .onTapGesture {
                selectedPath = row.id
                treeFocused = row.entry.directory
                if row.entry.directory { Task { await workspace.toggle(row.entry.path) } } else { model.open(row.entry.path) }
            }
            .contextMenu { menu(row) }
    }

    @ViewBuilder private func menu(_ row: TreeRow) -> some View {
        let entry = row.entry
        if entry.directory {
            Button("进入此目录") { Task { await workspace.browse(entry.path) } }
            Button("新建文件") { prompt = NamePrompt(title: "新文件名称", initial: "", action: .newFile(entry.path)) }
            Button("新建文件夹") { prompt = NamePrompt(title: "新文件夹名称", initial: "", action: .newFolder(entry.path)) }
        } else {
            Button("打开") { model.open(entry.path) }
            Button("附加到消息") { model.attach(entry.path) }
            Button("下载…") { model.download(entry.path) }
            Button("用本机软件打开") { model.openLocally(entry.path) }
            if row.gitCode != nil { Button("查看变更") { model.showingChat = false; Task { await workspace.openDiff(entry.path) } } }
        }
        Button("复制路径") { copyToPasteboard(entry.path) }
        Divider()
        Button("重命名…") { prompt = NamePrompt(title: "重命名", initial: entry.name, action: .rename(entry)) }
        Button("删除…", role: .destructive) { remove(entry) }
    }

    private func remove(_ entry: FileEntry) {
        model.presentation = .confirmation(WorkbenchConfirmation(
            title: entry.directory ? "删除文件夹及其全部内容？" : "删除文件？",
            detail: entry.path + "\n此操作在服务器上执行，无法撤销。", actionTitle: "删除", destructive: true) {
                model.perform { try await workspace.remove(entry) }
            })
    }

    /// A conversation with messages keeps its context, so a new folder starts a new conversation.
    private func useFolder() {
        guard let root = workspace.root else { return }
        model.openProjectPicker(root)
    }
}

struct NameSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    let prompt: NamePrompt
    let workspace: Workspace
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeading(title: prompt.title) { dismiss() }
            TextField("名称", text: $name).textFieldStyle(WorkbenchTextFieldStyle()).onSubmit(confirm)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确定", action: confirm).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { name = prompt.initial }
    }

    private func confirm() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismiss()
        model.perform {
            switch prompt.action {
            case .newFile(let directory): try await workspace.createEntry(in: directory, name: value, folder: false)
            case .newFolder(let directory): try await workspace.createEntry(in: directory, name: value, folder: true)
            case .rename(let entry): if value != entry.name { try await workspace.rename(entry, to: value) }
            }
        }
    }
}

struct ChangesView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace

    var body: some View {
        let status = workspace.gitStatus
        VStack(alignment: .leading, spacing: 0) {
            Text(summary(status))
                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(status?.files ?? []) { file in
                        Button { model.showingChat = false; Task { await workspace.openDiff(file.path) } } label: {
                            HStack {
                                Text(file.relative).foregroundStyle(gitColor(file.code)).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(file.status.trimmingCharacters(in: .whitespaces)).foregroundStyle(WorkbenchTheme.inkMuted)
                            }
                            .font(.callout).padding(.horizontal, 10).padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(file.path)
                    }
                }
            }
        }
        .task(id: model.showFiles && model.sidebarVisible && model.panel == .changes) {
            if model.showFiles && model.sidebarVisible && model.panel == .changes { await workspace.refreshGit() }
        }
    }

    private func summary(_ status: GitStatus?) -> String {
        guard let status else { return "读取中…" }
        guard status.repository else { return "当前目录不是 Git 仓库" }
        return (status.branch ?? "") + (status.files.isEmpty ? " · 没有未提交的变更" : "")
    }
}

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    @Bindable var state: WorkspaceSearchState
    @State private var collapsed = Set<String>()
    @FocusState private var focused: Bool

    private var visible: Bool { model.showFiles && model.sidebarVisible && model.panel == .search }
    private var groups: [(path: String, matches: [SearchMatch])] {
        var paths: [String] = []
        var grouped: [String: [SearchMatch]] = [:]
        for match in state.matches {
            if grouped[match.path] == nil { paths.append(match.path) }
            grouped[match.path, default: []].append(match)
        }
        return paths.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                TextField("搜索", text: $state.query).focused($focused).onSubmit { run() }
                    .onExitCommand { focused = false; model.focusWorkspace() }
                if state.searching { ProgressView().controlSize(.mini) }
                else if !state.query.isEmpty {
                    Button { state.query = "" } label: { WorkbenchIcon(symbol: "xmark") }
                        .buttonStyle(QuietButtonStyle()).help("清空").accessibilityLabel("清空搜索")
                }
            }.padding(8)
            if !state.status.isEmpty {
                Text(state.matches.isEmpty ? state.status : "\(state.matches.count) 处 · \(groups.count) 个文件" + (state.status.contains("部分") ? " · 部分结果" : ""))
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.path) { group in
                        Button {
                            if collapsed.contains(group.path) { collapsed.remove(group.path) }
                            else { collapsed.insert(group.path) }
                        } label: {
                            HStack(spacing: 5) {
                                WorkbenchIcon(symbol: "chevron.right").font(.system(size: 9))
                                    .rotationEffect(.degrees(collapsed.contains(group.path) ? 0 : 90))
                                FileIcon(name: group.path)
                                Text((group.path as NSString).lastPathComponent).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(group.matches.count)").foregroundStyle(WorkbenchTheme.inkMuted)
                            }.font(.system(size: 12)).frame(height: 24)
                        }.buttonStyle(QuietButtonStyle()).help(group.path)
                        if !collapsed.contains(group.path) {
                            ForEach(group.matches) { match in
                                Button { model.open(match.path, line: match.line) } label: {
                                    HStack(spacing: 6) {
                                        Text(highlight(match.text.trimmingCharacters(in: .whitespaces)))
                                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(match.line)").foregroundStyle(WorkbenchTheme.inkDim)
                                    }.font(.system(size: 11, design: .monospaced)).padding(.leading, 20).frame(height: 24)
                                }.buttonStyle(QuietButtonStyle()).help("\(match.relative):\(match.line)")
                            }
                        }
                    }
                }.padding(.horizontal, 4)
            }
        }
        .task(id: state.query) { if model.isConnected { state.run(in: workspace, delay: true) } }
        .task(id: visible) { await Task.yield(); focused = visible }
        .onChange(of: model.sidebarFocus) { if visible { focused = true } }
        .task(id: workspace.root) {
            state.updateRoot(workspace.root)
            if visible && model.isConnected { state.run(in: workspace, delay: true) }
        }
    }

    private func highlight(_ value: String) -> AttributedString {
        var result = AttributedString(value)
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        var start = value.startIndex
        while start < value.endIndex, let match = value.range(of: query, options: .caseInsensitive, range: start..<value.endIndex) {
            if let range = Range(match, in: result) { result[range].backgroundColor = WorkbenchTheme.accent.opacity(0.18) }
            start = match.upperBound
        }
        return result
    }

    private func run() { if model.isConnected { state.run(in: workspace) } }
}


extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct EditorPane: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    var showsTabs = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if showsTabs {
            // Tabs 26 pt tall with 4 pt gaps, centred in a 40 pt bar, as in the reference.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        EditorTabButton(tab: tab, active: tab.id == workspace.activeTabId,
                                        select: { Task { await workspace.select(tab) } },
                                        close: { model.close(tab, in: workspace) })
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .padding(.horizontal, 7)
                .animation(Motion.animation(Motion.slide, reduce: reduceMotion), value: workspace.tabs.map(\.id))
            }
            .frame(height: 40)
            }
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            if let tab = workspace.activeTab {
                header(tab)
                if tab.conflict {
                    Text("服务器上的文件已被修改。保存会被拒绝，请先复制你的修改再重新打开。")
                        .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(WorkbenchTheme.warning.opacity(0.15))
                }
                EditorContentDeck(workspace: workspace).id(ObjectIdentifier(workspace)).clipped()
                EditorStatusBar(tab: tab, workspace: workspace)
            }
        }
    }

    /// The tab's path relative to the workspace root, as breadcrumbs.
    private func breadcrumbs(_ tab: EditorTab) -> [String] {
        var path = tab.path
        if let root = workspace.root, path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
        return path.split(separator: "/").map(String.init)
    }

    private func header(_ tab: EditorTab) -> some View {
        let preview = tab.preview
        let parts = breadcrumbs(tab)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { WorkbenchIcon(symbol: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkDim) }
                        if index == parts.count - 1 { FileIcon(name: part).frame(width: 14) }
                        Text(part).font(.system(size: 11.5)).lineLimit(1)
                            .foregroundStyle(index == parts.count - 1 ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                    }
                }
                .help(tab.path)
                if tab.notice != nil || tab.error != nil || preview == nil || preview?.truncated == true {
                    Text(tab.notice ?? tab.error.map { _ in "无法预览" } ?? info(tab)).font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1)
                }
                if !tab.isDiff, let preview {
                    if tab.draft != nil {
                        Button("保存到远端") { Task { await workspace.save(tab) } }
                    } else if preview.kind == "text", preview.truncated != true, preview.revision != nil {
                        Button("编辑") { workspace.beginEditing(tab) }.disabled(tab.isValidating || tab.error != nil)
                    }
                    if preview.kind == "text", (isMarkdown(preview) || FilePreviewSupport.hasVisualPreview(preview.name)), tab.draft == nil {
                        Button(tab.showSource ? "预览" : "源码") { tab.showSource.toggle() }
                    }
                    if preview.kind == "text", preview.truncated == true, (preview.nextOffset ?? 1048576) < 1048576 {
                        Button("加载更多") { Task { await workspace.loadMoreText(tab) } }.disabled(tab.isValidating)
                    }
                    if preview.thumbnail == true {
                        Button("查看原图") { Task { await workspace.open(preview.path, original: true) } }.disabled(tab.isValidating)
                    }
                    if tab.isValidating { ProgressView().controlSize(.mini).help("检查远端版本") }
                    Spacer(minLength: 0)
                    Button { model.download(preview.path) } label: { WorkbenchIcon(symbol: "arrow.down.to.line") }
                        .buttonStyle(WorkbenchIconButtonStyle()).help("下载到本机…").accessibilityLabel("下载到本机")
                    WorkbenchMenu(iconOnly: true) {
                        Button("附加到对话") { model.attach(preview.path) }
                        Button("下载…") { model.download(preview.path) }
                        Button("本地打开") { model.openLocally(preview.path) }
                        Button("复制路径") { copyToPasteboard(preview.path) }
                    } label: { WorkbenchIcon(symbol: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("文件操作").accessibilityLabel("文件操作")
                }
            }
        }
        .controlSize(.small).buttonStyle(QuietButtonStyle()).padding(.horizontal, 10).frame(height: 30)
    }

    private func info(_ tab: EditorTab) -> String {
        if tab.isDiff { return "Git 变更" }
        guard let preview = tab.preview else { return "读取中…" }
        return byteText(preview.size) + (preview.truncated == true ? " · 已加载 " + byteText(preview.nextOffset ?? 1048576) : "")
    }
}

/// A tab: file mark, title, and a close button that appears on hover or for the current tab.
struct EditorTabButton: View {
    let tab: EditorTab
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            FileIcon(name: (tab.path as NSString).lastPathComponent).frame(width: 16)
            Text(tab.title).font(.system(size: 12, weight: active ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(active ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
            ZStack {
                if tab.isDirty && !hovered {
                    Circle().fill(WorkbenchTheme.ink.opacity(0.6)).frame(width: 7, height: 7).accessibilityLabel("未保存")
                } else {
                    Button(action: close) { WorkbenchIcon(symbol: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 16, height: 16) }
                        .buttonStyle(WorkbenchIconButtonStyle(size: 20))
                        .foregroundStyle(WorkbenchTheme.inkMuted)
                        .opacity(active || hovered ? 1 : 0)
                        .help("关闭 " + tab.title).accessibilityLabel("关闭 " + tab.title)
                }
            }.frame(width: 16, height: 16)
        }
        .padding(.leading, 8).padding(.trailing, 5)
        .frame(minWidth: 80, maxWidth: 180, minHeight: 26, maxHeight: 26)
        .background(active ? WorkbenchTheme.userBubble : hovered ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(active ? WorkbenchTheme.accent.opacity(0.35) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .help(tab.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}

/// A 26 pt status line under the editor: branch on the left, position and file facts on the right.
struct EditorStatusBar: View {
    let tab: EditorTab
    let workspace: Workspace

    var body: some View {
        let kind = FileKind.of((tab.path as NSString).lastPathComponent)
        let text = tab.draft ?? tab.preview?.text
        HStack(spacing: 14) {
            Spacer(minLength: 8)
            if let line = tab.line { Text("第 \(line) 行") }
            if tab.isDiff { Text("变更") } else {
                Text(kind.language)
                if let text {
                    Text("UTF-8")
                    Text("\(text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }) 行")
                }
                if let size = tab.preview?.size { Text(byteText(size)) }
            }
        }
        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 26)
        .overlay(alignment: .top) { Rectangle().fill(WorkbenchTheme.separator).frame(height: 1) }
    }
}

func isMarkdown(_ preview: FilePreview) -> Bool {
    let name = preview.name.lowercased()
    return (name.hasSuffix(".md") || name.hasSuffix(".markdown")) && preview.truncated != true
}

/// Keep the three most recently viewed file surfaces alive, including scroll and decoded previews.
private struct EditorContentDeck: View {
    let workspace: Workspace
    @State private var recent: [String] = []
    private var tabs: [EditorTab] {
        workspace.tabs.filter { recent.contains($0.id) || $0.id == workspace.activeTabId }
    }
    var body: some View {
        let tabs = tabs
        RetainedPaneLayout(selection: tabs.firstIndex { $0.id == workspace.activeTabId } ?? 0) {
            ForEach(tabs) { tab in
                EditorContent(tab: tab, workspace: workspace)
                    .paneVisible(tab.id == workspace.activeTabId)
            }
        }
        .onChange(of: workspace.activeTabId, initial: true) {
            guard let id = workspace.activeTabId else { return }
            recent.removeAll { candidate in candidate == id || !workspace.tabs.contains(where: { $0.id == candidate }) }
            recent.append(id)
            recent = Array(recent.suffix(3))
        }
        .transaction { $0.animation = nil }
    }
}

struct EditorContent: View {
    @EnvironmentObject private var model: AppModel
    let tab: EditorTab
    let workspace: Workspace

    var body: some View {
        Group {
            if let error = tab.error, tab.preview == nil {
                Text(error).foregroundStyle(WorkbenchTheme.inkMuted).padding().textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if tab.isDiff {
                if let text = tab.diffText {
                    SplitDiffView(text: text, path: tab.path)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else if let preview = tab.preview {
                VStack(spacing: 0) {
                    if let error = tab.error {
                        Text("刷新失败，保留上次加载的内容：" + error)
                            .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkbenchTheme.warning.opacity(0.08))
                    }
                    content(preview)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func content(_ preview: FilePreview) -> some View {
        switch preview.kind {
        case "text":
            if tab.draft != nil {
                TextEditor(text: Binding(get: { tab.draft ?? "" }, set: { tab.draft = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).background(WorkbenchTheme.surface)
            } else if FilePreviewSupport.hasVisualPreview(preview.name), !tab.showSource {
                RemoteDocumentPreview(preview: preview, workspace: workspace)
            } else {
                CodeTextView(text: preview.text ?? "", line: tab.line, path: tab.path, focusToken: model.editorFocus)
            }
        case "image":
            RemoteDocumentPreview(preview: preview, workspace: workspace)
        case "pdf":
            if let data = preview.data { PDFContent(data: data) }
        default:
            if FilePreviewSupport.hasVisualPreview(preview.name) {
                RemoteDocumentPreview(preview: preview, workspace: workspace)
            } else {
                VStack(spacing: 12) {
                    FileIcon(name: preview.name).frame(width: 32, height: 32)
                    Text("此格式暂不支持预览").foregroundStyle(WorkbenchTheme.inkMuted)
                    HStack {
                        Button("下载…") { model.download(preview.path) }
                        Button("本地打开") { model.openLocally(preview.path) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct PDFContent: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ view: PDFView, context: Context) {
        // Comparing against the document's own bytes would re-serialize it on every update.
        if context.coordinator.shown != data { context.coordinator.shown = data; view.document = PDFDocument(data: data) }
    }
    final class Coordinator { var shown: Data? }
}

/// AppKit's text system handles megabyte files that a SwiftUI Text cannot. Code is coloured by
/// file type, and line numbers live in a ruler so copied text never contains them.
struct CodeTextView: NSViewRepresentable {
    let text: String
    let line: Int?
    var path: String = ""
    var focusToken: UUID?

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var text: String?; var line: Int?; var path: String?; var focusToken: UUID? }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.drawsBackground = false
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = CodeStyle.font
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.selectedTextAttributes = [.backgroundColor: NSTheme.selection]
        // ⌘F / ⌘G use AppKit's find bar, with incremental highlighting as you type.
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        scroll.findBarPosition = .aboveContent
        // Long lines scroll rather than wrap, so line numbers from Claude stay meaningful.
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        let ruler = LineNumberRuler(textView: view, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let ruler = scroll.verticalRulerView as? LineNumberRuler else { return }
        // Updates arrive constantly while Claude works; only real changes may move the view.
        let coordinator = context.coordinator
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        guard coordinator.text != text || coordinator.line != line || coordinator.path != path else { return }
        let lineChanged = coordinator.line != line
        if coordinator.text != text || coordinator.path != path {
            let visible = scroll.contentView.bounds.origin
            view.textStorage?.setAttributedString(CodeStyle.attributed(text, grammar: SyntaxGrammar.forFile(path)))
            ruler.reload()
            scroll.contentView.scroll(to: visible)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.text = text; coordinator.line = line; coordinator.path = path
        ruler.activeLine = line
        guard lineChanged, let line, line > 0, let range = ruler.range(ofLine: line) else { return }
        DispatchQueue.main.async {
            // Reveal the start, not the entire long line: the latter scrolls sideways
            // when the editor first appears in a narrow split.
            let insertion = NSRange(location: range.location, length: 0)
            view.setSelectedRange(insertion)
            view.scrollRangeToVisible(insertion)
            // NSScrollView's leading bound can be negative when a ruler adds insets.
            var leadingBounds = scroll.contentView.bounds
            leadingBounds.origin.x = -1_000_000
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(leadingBounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

/// Draws line numbers beside a non-wrapping text view, using the same font and line height so
/// every number sits on its line's baseline.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    var activeLine: Int? { didSet { if activeLine != oldValue { needsDisplay = true } } }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }
    @objc private func scrolled() { needsDisplay = true }

    /// Re-indexes line starts after the text changes.
    func reload() {
        var starts = [0]
        if let text = textView?.string {
            var index = 0
            for unit in text.utf16 { index += 1; if unit == 10 { starts.append(index) } }
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let width = ("8" as NSString).size(withAttributes: [.font: CodeStyle.font]).width
        ruleThickness = ceil(CGFloat(digits) * width + 22)
        needsDisplay = true
    }

    /// The character range of a 1-based line, without its line break.
    func range(ofLine line: Int) -> NSRange? {
        guard line >= 1, line <= lineStarts.count, let length = (textView?.string as NSString?)?.length else { return nil }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSTheme.card.setFill(); bounds.fill()
        NSTheme.border.setFill(); NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        let paragraph = CodeStyle.paragraph(); paragraph.alignment = .right
        let origin = textView.textContainerOrigin
        func draw(_ number: Int, fragment: NSRect) {
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let attributes: [NSAttributedString.Key: Any] = [.font: CodeStyle.font, .paragraphStyle: paragraph, .baselineOffset: CodeStyle.baselineOffset(CodeStyle.font),
                                                             .foregroundColor: number == activeLine ? NSTheme.gutterActive : NSTheme.gutter]
            NSAttributedString(string: String(number), attributes: attributes)
                .draw(in: NSRect(x: 0, y: top, width: ruleThickness - 12, height: fragment.height))
        }
        guard length > 0 else { draw(1, fragment: layout.extraLineFragmentRect); return }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // The first visible line: the last start at or before the first visible character.
        var low = 0, high = lineStarts.count - 1
        while low < high { let mid = (low + high + 1) / 2; if lineStarts[mid] <= characters.location { low = mid } else { high = mid - 1 } }
        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let fragment = start >= length ? layout.extraLineFragmentRect
                : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            draw(line + 1, fragment: fragment)
            line += 1
        }
    }
}
#endif
