import SwiftUI
import RemoteCCCore

private enum PaletteCommand: String, CaseIterable, Identifiable {
    case conversation, files, search, settings, connect, preferences
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conversation: "新建对话"
        case .files: "打开文件面板"
        case .search: "在项目中搜索"
        case .settings: "打开设置"
        case .connect: "连接 SSH 主机"
        case .preferences: "模型与会话设置"
        }
    }
    var icon: String {
        switch self {
        case .conversation: "square.and.pencil"
        case .files: "sidebar.right"
        case .search: "doc.text.magnifyingglass"
        case .settings: "slider.horizontal.3"
        case .connect: "server.rack"
        case .preferences: "cpu"
        }
    }
    var shortcut: String {
        switch self {
        case .conversation: "⌘ N"
        case .files: "⌘ B"
        case .search: "⇧ ⌘ F"
        case .settings: "⌘ ,"
        default: ""
        }
    }
    @MainActor func perform(_ model: AppModel) {
        switch self {
        case .conversation: model.newConversation()
        case .files: model.openPanel(.files)
        case .search: model.openPanel(.search)
        case .settings: model.presentation = .settings
        case .connect: model.presentation = .connect
        case .preferences: model.presentation = .preferences
        }
    }
}

private enum PaletteEntry: Identifiable {
    case file(FileEntry)
    case command(PaletteCommand)
    var id: String {
        switch self { case .file(let file): "file:" + file.path; case .command(let command): "command:" + command.id }
    }
}

struct QuickOpenSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var status = ""
    @State private var files: [FileEntry] = []
    @State private var selected: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var commandsOnly: Bool { query.hasPrefix(">") }
    private var entries: [PaletteEntry] {
        let term = query.trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        let commands = PaletteCommand.allCases.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) }
        return (commandsOnly ? [] : files.map(PaletteEntry.file)) + commands.map(PaletteEntry.command)
    }
    private var current: PaletteEntry? { entries.first { $0.id == selected } ?? entries.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                WorkbenchIcon(symbol: commandsOnly ? "chevron.right" : "magnifyingglass").foregroundStyle(WorkbenchTheme.inkMuted)
                TextField("搜索文件，输入 > 执行命令", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let current { choose(current) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { model.presentation = nil; return .handled }
                WorkbenchShortcut(keys: "esc")
            }.padding(.horizontal, 16).frame(height: 48)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if entries.isEmpty { InterfaceState(title: "没有匹配结果", detail: status, symbol: "magnifyingglass") }
                        ForEach(entries) { entry in
                            Button { choose(entry) } label: { row(entry) }
                                .buttonStyle(.plain).id(entry.id)
                                .background(current?.id == entry.id ? WorkbenchTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .onHover { if $0 { selected = entry.id } }
                        }
                    }.padding(6)
                }.frame(height: 300)
                    .onChange(of: selected) { if let selected { proxy.scrollTo(selected) } }
            }
            WorkbenchStatusBar {
                WorkbenchShortcut(keys: "↑ ↓"); Text("选择")
                WorkbenchShortcut(keys: "↵"); Text("打开")
                Spacer()
                Text(status.isEmpty ? "文件与命令" : status).lineLimit(1)
            }
        }
        .frame(width: 600)
        .onChange(of: query) { search() }
        .defaultFocus($focused, true)
        .task { search(); await Task.yield(); focused = true }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private func row(_ entry: PaletteEntry) -> some View {
        HStack(spacing: 10) {
            switch entry {
            case .file(let file):
                FileIcon(name: file.name)
                Text(file.name).lineLimit(1)
                Text(file.relative ?? file.path).foregroundStyle(WorkbenchTheme.inkDim).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            case .command(let command):
                WorkbenchIcon(symbol: command.icon).frame(width: 16).foregroundStyle(WorkbenchTheme.inkMuted)
                Text(command.title)
                Spacer()
                if !command.shortcut.isEmpty { WorkbenchShortcut(keys: command.shortcut) }
            }
        }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
    }
    private func move(_ direction: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == current?.id } ?? 0
        selected = entries[min(max(index + direction, 0), entries.count - 1)].id
    }
    private func choose(_ entry: PaletteEntry) {
        model.presentation = nil
        switch entry {
        case .file(let file): model.open(file.path)
        case .command(let command): command.perform(model)
        }
    }
    private func search() {
        task?.cancel(); files = []; selected = nil
        guard !commandsOnly else { status = "命令"; return }
        guard let workspace = model.activeWorkspace, model.isConnected else { status = "连接项目后搜索文件"; return }
        #if DEBUG
        if Bundle.main.bundleIdentifier == "local.claudemirror.demo" {
            files = workspace.rows.filter { !$0.entry.directory }.map(\.entry).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            status = "示例项目"; return
        }
        #endif
        status = "查找文件…"
        let term = query
        task = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await workspace.suggest(term)
                guard !Task.isCancelled else { return }
                files = result; status = "\(result.count) 个文件"
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}
