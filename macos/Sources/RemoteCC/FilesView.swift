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
            HStack(spacing: 6) {
                PanelSegments(selection: $model.panel, changes: model.activeWorkspace?.gitStatus?.files.count ?? 0)
                Spacer(minLength: 4)
                Button { model.showFiles = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(QuietButtonStyle()).help("关闭文件面板").accessibilityLabel("关闭文件面板")
            }.padding(.horizontal, 8).frame(height: 40)
            if let workspace = model.activeWorkspace {
                if !model.isConnected {
                    Label("连接已断开", systemImage: "network.slash")
                        .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(8)
                }
                Group {
                    switch model.panel {
                    case .files: FileTreeView(workspace: workspace)
                    case .changes: ChangesView(workspace: workspace)
                    case .search: SearchView(workspace: workspace)
                    }
                }.disabled(!model.isConnected)
            } else {
                ContentUnavailableView("未连接 SSH", systemImage: "network.slash").frame(maxHeight: .infinity)
            }
        }.background { FrostedBackground() }
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
            Image(systemName: "chevron.right")
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

/// Icon tabs for the workspace panel, like the reference sidebar's mode buttons.
struct PanelSegments: View {
    @Binding var selection: SidePanel
    let changes: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var marker

    private func symbol(_ panel: SidePanel) -> String {
        switch panel { case .files: "doc.on.doc"; case .changes: "arrow.triangle.branch"; case .search: "magnifyingglass" }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidePanel.allCases) { panel in
                Button { selection = panel } label: {
                    Image(systemName: symbol(panel)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == panel ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                        .frame(width: 30, height: 24)
                        .background {
                            if selection == panel {
                                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small).fill(WorkbenchTheme.popup)
                                    .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small).strokeBorder(WorkbenchTheme.popupBorder))
                                    .matchedGeometryEffect(id: "segment", in: marker)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if panel == .changes && changes > 0 {
                                Circle().fill(WorkbenchTheme.accent).frame(width: 6, height: 6).offset(x: -4, y: 3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(panel == .changes && changes > 0 ? "变更 \(changes)" : panel.rawValue)
                .accessibilityLabel(panel == .changes && changes > 0 ? "变更 \(changes)" : panel.rawValue)
                .accessibilityAddTraits(selection == panel ? .isSelected : [])
            }
        }
        .padding(2)
        .background(WorkbenchTheme.hover, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
        .animation(Motion.animation(Motion.slide, reduce: reduceMotion), value: selection)
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
    @State private var prompt: NamePrompt?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rootName: String {
        guard let root = workspace.root else { return "工作区" }
        return root == "/" ? "/" : (root as NSString).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            projectRow
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).padding(.horizontal, 12).padding(.bottom, 4).textSelection(.enabled) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(workspace.rows) { row in
                        rowView(row).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
                .animation(Motion.animation(Motion.tree, reduce: reduceMotion), value: workspace.rows.map(\.id))
            }
            .overlay { if workspace.rows.isEmpty && workspace.error == nil && workspace.root != nil { InterfaceState(title: "空目录", detail: "可上传文件，或从目录菜单新建文件。", symbol: "folder") } }
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            Text(workspace.footer).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 26)
        }
        .onAppear { path = workspace.root ?? model.active?.directory ?? "~" }
        .onChange(of: workspace.root) { if let root = workspace.root { path = root } }
        .sheet(item: $prompt) { NameSheet(prompt: $0, workspace: workspace).workbenchPanel() }
    }

    /// The project name with its menu and quick actions, as in the reference sidebar.
    private var projectRow: some View {
        HStack(spacing: 6) {
            if editingPath {
                TextField("远端目录", text: $path).textFieldStyle(WorkbenchTextFieldStyle()).font(.system(size: 11.5, design: .monospaced))
                    .focused($pathFocused)
                    .onSubmit { editingPath = false; Task { await workspace.browse(path) } }
                    .onExitCommand { editingPath = false }
                    .onAppear { pathFocused = true }
            } else {
                Menu {
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
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkMuted)
                    }
                }
                // The button style keeps the custom label; a borderless menu would drop it.
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(workspace.root ?? "").accessibilityLabel("目录：" + rootName)
                Spacer(minLength: 4)
                Group {
                    iconButton("doc.badge.plus", "新建文件") { if let root = workspace.root { prompt = NamePrompt(title: "新文件名称", initial: "", action: .newFile(root)) } }
                    iconButton("folder.badge.plus", "新建文件夹") { if let root = workspace.root { prompt = NamePrompt(title: "新文件夹名称", initial: "", action: .newFolder(root)) } }
                    iconButton("arrow.clockwise", "刷新") { Task { await workspace.reload(force: true) } }
                    iconButton("square.and.arrow.up", "上传文件") { model.pickAndUpload(to: workspace.root) }
                }.disabled(workspace.root == nil)
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 32)
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 14, height: 14) }
            .buttonStyle(QuietButtonStyle()).foregroundStyle(WorkbenchTheme.inkMuted)
            .help(title).accessibilityLabel(title)
    }

    private func rowView(_ row: TreeRow) -> some View {
        FileTreeRow(row: row, selected: workspace.activeTab.map { !$0.isDiff && $0.path == row.entry.path } ?? false)
            .help(row.entry.path)
            .onTapGesture(count: 2) { if row.entry.directory { Task { await workspace.browse(row.entry.path) } } }
            .simultaneousGesture(TapGesture().onEnded {
                if row.entry.directory { Task { await workspace.toggle(row.entry.path) } } else { model.open(row.entry.path) }
            })
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
            if row.gitCode != nil { Button("查看变更") { Task { await workspace.openDiff(entry.path) } } }
        }
        Button("复制路径") { copyToPasteboard(entry.path) }
        Divider()
        Button("重命名…") { prompt = NamePrompt(title: "重命名", initial: entry.name, action: .rename(entry)) }
        Button("删除…", role: .destructive) { remove(entry) }
    }

    private func remove(_ entry: FileEntry) {
        let alert = NSAlert()
        alert.messageText = entry.directory ? "删除文件夹 \(entry.path) 及其全部内容？" : "删除文件 \(entry.path)？"
        alert.informativeText = "此操作在服务器上执行，无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        model.perform { try await workspace.remove(entry) }
    }

    /// A conversation with messages keeps its context, so a new folder starts a new conversation.
    private func useFolder() {
        guard let root = workspace.root else { return }
        model.openProjectPicker(root)
    }
}

struct NameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prompt: NamePrompt
    let workspace: Workspace
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title).font(.headline)
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
    let workspace: Workspace

    var body: some View {
        let status = workspace.gitStatus
        VStack(alignment: .leading, spacing: 0) {
            Text(summary(status))
                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(status?.files ?? []) { file in
                        Button { Task { await workspace.openDiff(file.path) } } label: {
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
        .task { await workspace.refreshGit() }
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
    @State private var query = ""
    @State private var status = ""
    @State private var matches: [SearchMatch] = []
    @State private var task: Task<Void, Never>?
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("搜索文件内容", text: $query)
                    .textFieldStyle(WorkbenchTextFieldStyle()).focused($focused).onSubmit(run)
                    .onExitCommand { query = "" }
                Button(action: run) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(QuietButtonStyle()).help("搜索 · Enter").accessibilityLabel("搜索文件内容")
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isConnected || searching)
            }.padding(8)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(.horizontal, 12).padding(.bottom, 8) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { match in
                        Button { model.open(match.path, line: match.line) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(match.relative):\(match.line)").font(.caption.weight(.medium)).lineLimit(1)
                                Text(match.text.trimmingCharacters(in: .whitespaces)).font(.system(size: 11, design: .monospaced)).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(QuietButtonStyle()).help(match.path)
                    }
                }.padding(.horizontal, 4)
            }.overlay {
                if searching {
                    InterfaceState(title: "正在搜索…", detail: "", loading: true)
                } else if matches.isEmpty && status.isEmpty {
                    InterfaceState(title: "搜索项目内容", detail: "输入关键词，按 Enter 搜索。点击结果可打开对应行。", symbol: "doc.text.magnifyingglass")
                }
            }
        }
        .task { await Task.yield(); focused = true }
        .onChange(of: query) { task?.cancel(); searching = false; matches = []; status = "" }
        .onDisappear { task?.cancel() }
    }

    private func run() {
        task?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, model.isConnected else { return }
        status = ""; matches = []; searching = true
        task = Task {
            do {
                let result = try await workspace.search(term)
                guard !Task.isCancelled else { return }
                matches = result.matches
                status = result.matches.isEmpty ? "没有找到匹配内容，试试其他关键词。" : "\(result.matches.count) 处匹配" + (result.truncated == true ? "（仅显示部分结果，请缩小搜索范围）" : "")
                searching = false
            } catch { if !Task.isCancelled { status = error.localizedDescription; searching = false } }
        }
    }
}

struct QuickOpenSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var status = ""
    @FocusState private var focused: Bool
    @State private var results: [FileEntry] = []
    @State private var selection = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            TextField("按名称查找服务器上的文件", text: $query)
                .textFieldStyle(WorkbenchTextFieldStyle()).focused($focused)
                .onSubmit { if let file = results[safeIndex: selection] { choose(file) } }
                .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(8) }
            MenuList(count: results.count, selection: selection) { index in
                let file = results[index]
                return AnyView(Button { choose(file) } label: {
                    Text(file.relative ?? file.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(file.path))
            }
        }
        .padding(10).frame(width: 560)
        .onChange(of: query) { search() }
        .task { await Task.yield(); focused = true; search() }
        .onDisappear { task?.cancel() }
    }

    private func search() {
        task?.cancel()
        results = []; selection = 0
        guard let workspace = model.activeWorkspace, model.isConnected else { status = "连接服务器并打开项目后查找文件。"; return }
        status = "正在查找…"
        let current = query
        task = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await workspace.suggest(current)
                guard !Task.isCancelled else { return }
                results = found; selection = 0
                status = found.isEmpty ? "未找到文件，试试其他名称。" : "↑ ↓ 选择 · Enter 打开 · Esc 关闭"
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }

    private func choose(_ file: FileEntry) { dismiss(); model.open(file.path) }
}

extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct EditorPane: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
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
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            if let tab = workspace.activeTab {
                header(tab)
                if tab.conflict {
                    Text("服务器上的文件已被修改。保存会被拒绝，请先复制你的修改再重新打开。")
                        .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(WorkbenchTheme.warning.opacity(0.15))
                }
                EditorContent(tab: tab, workspace: workspace).id(tab.id)
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
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkDim) }
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
                    if isMarkdown(preview), tab.draft == nil {
                        Button(tab.showSource ? "预览" : "源码") { tab.showSource.toggle(); model.objectWillChange.send() }
                    }
                    if preview.kind == "text", preview.truncated == true, (preview.nextOffset ?? 1048576) < 1048576 {
                        Button("加载更多") { Task { await workspace.loadMoreText(tab) } }.disabled(tab.isValidating)
                    }
                    if preview.thumbnail == true {
                        Button("查看原图") { Task { await workspace.open(preview.path, original: true) } }.disabled(tab.isValidating)
                    }
                    if tab.isValidating { ProgressView().controlSize(.mini).help("检查远端版本") }
                    Spacer(minLength: 0)
                    Menu {
                        Button("附加到对话") { model.attach(preview.path) }
                        Button("下载…") { model.download(preview.path) }
                        Button("本地打开") { model.openLocally(preview.path) }
                        Button("复制路径") { copyToPasteboard(preview.path) }
                    } label: { Image(systemName: "ellipsis") }
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
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 16, height: 16) }
                        .buttonStyle(QuietButtonStyle()).padding(-7)
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
            if let branch = workspace.gitStatus?.branch {
                Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
            }
            if let count = workspace.gitStatus?.files.count, count > 0 { Text("\(count) 项变更") }
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
                    let rows = unifiedDiffRows(text)
                    if rows.isEmpty { Text("没有差异").foregroundStyle(WorkbenchTheme.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { DiffView(rows: rows) }
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
                TextEditor(text: Binding(get: { tab.draft ?? "" }, set: { tab.draft = $0; model.objectWillChange.send() }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).background(WorkbenchTheme.surface)
            } else if isMarkdown(preview), !tab.showSource {
                ScrollView {
                    MarkdownView(text: preview.text ?? "", actions: FileActions(open: { model.open($0, line: $1) }))
                        .textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                CodeTextView(text: preview.text ?? "", line: tab.line, path: tab.path)
            }
        case "image":
            if let data = preview.data, let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding() }
            } else { Text("无法显示图片").foregroundStyle(WorkbenchTheme.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case "pdf":
            if let data = preview.data { PDFContent(data: data) }
        default:
            Text(preview.reason ?? "此格式请下载或在本地打开").foregroundStyle(WorkbenchTheme.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
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

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var text: String?; var line: Int?; var path: String? }

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
            view.scrollRangeToVisible(range)
            view.setSelectedRange(range)
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
