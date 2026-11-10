#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RemoteCCCore

struct ComposerArea: View {
    @EnvironmentObject private var model: AppModel
    @State private var editorHeight: CGFloat = 40
    @State private var caret = 0
    @State private var selection = 0
    @State private var dismissedText: String?
    @State private var mentions: [FileEntry] = []
    @State private var mentionTask: Task<Void, Never>?
    @State private var dropTarget = false
    @State private var changingModel = false
    @State private var showingCommands = false
    @State private var showingModels = false

    private var id: String { model.activeId ?? "welcome-" + (model.currentConfig?.key ?? "local") }
    private var canSend: Bool {
        model.active.map { !model.projectMissing($0) } != false &&
        !model.uploadingSessions.contains(id) && model.currentConfig != nil && model.isConnected && model.active?.historyLoaded != false &&
        (!text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(model.attachments[id] ?? []).isEmpty)
    }
    private var text: Binding<String> {
        Binding(get: { model.drafts[id] ?? "" }, set: { model.drafts[id] = $0 })
    }

    private var completions: [RemoteCommand] {
        let value = text.wrappedValue
        guard value != dismissedText, let token = CommandCompletion.token(value, caret: caret), let commands = model.active?.capabilities?.commands else { return [] }
        return CommandCompletion.match(CommandCompletion.candidates(commands), query: token.query)
    }

    /// `@query` immediately before the caret.
    private var mentionRange: NSRange? {
        let value = text.wrappedValue as NSString
        guard caret <= value.length else { return nil }
        let before = value.substring(to: caret)
        guard let range = before.range(of: "(^|\\s)@[^\\s@]*$", options: .regularExpression) else { return nil }
        let match = NSRange(range, in: before)
        let at = (before as NSString).range(of: "@", options: .backwards, range: match)
        return NSRange(location: at.location, length: caret - at.location)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.isConnected {
                HStack(spacing: 8) {
                    Label(model.connectionState.status == .connecting ? "正在连接服务器…" : "未连接 · 草稿会保留", systemImage: "network.slash")
                    Spacer()
                    if model.connectionState.status != .connecting, let config = model.currentConfig {
                        Button("重新连接") { model.perform { try await model.connect(config) } }
                    }
                }.font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(.horizontal, 4)
            }
            if let session = model.active {
                todoStrip(session)
                ForEach(session.permissions) { permission in
                    PermissionCard(permission: permission).id(permission.id)
                }
                queue(session)
            }
            if !completions.isEmpty { commandMenu }
            else if !mentions.isEmpty { mentionMenu }
            VStack(alignment: .leading, spacing: 6) {
                attachmentChips
                if model.uploadingSessions.contains(id) { ProgressView("正在上传附件…").controlSize(.small).font(.caption) }
                ForEach(model.failedUploads[id] ?? [], id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent + " 上传失败", systemImage: "exclamationmark.circle").lineLimit(1)
                        Spacer()
                        Button("重试") { model.upload([url], to: model.failedUploadDirectories[id]?[url]) }.disabled(model.uploadingSessions.contains(id) || !model.isConnected)
                        Button("移除") { model.failedUploads[id]?.removeAll { $0 == url } }
                    }.font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                PromptEditor(text: text, caret: $caret, placeholder: "发送消息，或输入 / 使用命令", handler: handleKey, onPasteImage: { model.pasteImage($0) }, onDropFiles: { model.upload($0) }, acceptsFileDrops: model.isConnected, onFileDrag: { dropTarget = $0 }, focusToken: model.composerFocus, onHeightChange: { editorHeight = $0 })
                    .frame(height: editorHeight)
                toolbarRow
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            .background {
                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large)
                    .fill(WorkbenchTheme.surface)
            }
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large).strokeBorder(dropTarget ? WorkbenchTheme.accent : WorkbenchTheme.border.opacity(0.6)))
            .shadow(color: .black.opacity(0.055), radius: 14, y: 4)
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                guard model.isConnected else { model.show("先连接服务器，再附加文件"); return false }
                let destinationId = id
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                let url: URL?
                                if let value = item as? URL { url = value }
                                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                                else { url = nil }
                                continuation.resume(returning: url?.isFileURL == true ? url : nil)
                            }
                        }
                        if let url { urls.append(url) }
                    }
                    guard id == destinationId else { model.show("对话已切换，请重新拖入文件"); return }
                    if urls.isEmpty { model.show("无法读取拖入的文件，请重试") }
                    else { model.upload(urls) }
                }
                return true
            }
            if !model.transferStatus.isEmpty {
                Text(model.transferStatus).lineLimit(1)
                    .font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted).padding(.horizontal, 4)
            }

        }
        .padding(.horizontal, 28).padding(.bottom, 14).padding(.top, 6)
        .frame(maxWidth: WorkbenchTheme.conversationWidth)
        .frame(maxWidth: .infinity)
        .onChange(of: text.wrappedValue) { refreshMentions() }
        .onChange(of: caret) { selection = 0 }
    }

    @ViewBuilder private func todoStrip(_ session: ChatSession) -> some View {
        if ["working", "permission", "connecting", "detached"].contains(session.status),
           let block = session.messages.last?.blocks?.last(where: { $0.name == "TodoWrite" }),
           case .todos(let items)? = ToolPresentation(name: block.name, input: block.input).body, !items.isEmpty {
            ScrollView { TodoList(items: items).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 130).fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.inkMuted.opacity(0.2)))
        }
    }

    @ViewBuilder private func queue(_ session: ChatSession) -> some View {
        if let queue = session.queue, !queue.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.queuePaused == true ? "队列已暂停" : "回复完成后依次发送").foregroundStyle(WorkbenchTheme.inkMuted)
                    if session.queuePaused == true {
                        Button("继续队列") { model.perform { try model.engine?.resumeQueue(session.id) } }.disabled(!model.isConnected)
                    }
                }
                ForEach(queue) { item in
                    HStack {
                        Text(item.text).lineLimit(1)
                        Spacer()
                        Button("取消") { model.perform { try model.engine?.cancelQueued(session.id, item: item.id) } }
                    }
                }
            }
            .font(.caption).controlSize(.small)
        }
    }

    private var commandMenu: some View {
        MenuList(count: completions.count, selection: selection) { index in
            let command = completions[index]
            return AnyView(Button { choose(command, execute: false) } label: {
                HStack(spacing: 10) {
                    Text("/" + command.name).font(.system(size: 12, design: .monospaced)).frame(minWidth: 90, alignment: .leading)
                    Text((command.description ?? "").components(separatedBy: "\n").first ?? "").foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1)
                    Spacer()
                    Text(command.argumentHint ?? "").font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain))
        }
    }

    private var mentionMenu: some View {
        MenuList(count: mentions.count, selection: selection) { index in
            let file = mentions[index]
            return AnyView(Button { chooseMention(file) } label: {
                Text(file.relative ?? file.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(file.path))
        }
    }

    @ViewBuilder private var attachmentChips: some View {
        if let files = model.attachments[id], !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(files) { file in
                        HStack(spacing: 5) {
                            Button(file.name) { model.open(file.path) }.buttonStyle(.plain).help(file.path)
                            Button { model.attachments[id]?.removeAll { $0.path == file.path } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("移除附件")
                        }
                        .font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(WorkbenchTheme.inkMuted.opacity(0.1), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
                    }
                }
            }
        }
    }

    private var toolbarRow: some View {
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { composerTools; sessionControls }
            VStack(alignment: .leading, spacing: 4) { composerTools; sessionControls }
        }
    }

    private var composerTools: some View {
        HStack(spacing: 4) {
            Menu {
                Button("添加文件", systemImage: "paperclip") { model.pickAndUpload() }
                if model.active != nil {
                    Divider()
                    Button("技能", systemImage: "sparkles") { model.openTools("skills") }
                    Button("连接器 · MCP", systemImage: "point.3.connected.trianglepath.dotted") { model.openTools("mcp") }
                    Button("插件", systemImage: "puzzlepiece.extension") { model.openTools("plugins") }
                    Divider()
                    Button("记忆与配置", systemImage: "doc.text") { model.openTools("config") }
                }
            } label: { Label("添加", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().help("添加文件、技能、连接器与插件").disabled(!model.isConnected)
            if model.active != nil {
                Button { showingCommands.toggle() } label: { Label("命令", systemImage: "terminal") }
                    .buttonStyle(QuietButtonStyle()).disabled(!model.isConnected)
                    .popover(isPresented: $showingCommands, arrowEdge: .top) {
                        let commands = CommandCompletion.candidates(model.active?.capabilities?.commands ?? [])
                        SearchPicker(title: "命令", items: commands.map {
                            SearchPickerItem(id: $0.name, title: "/" + $0.name, detail: $0.description ?? "")
                        }, refresh: { model.refreshCapabilities(force: true) }) { name in
                            if let command = commands.first(where: { $0.name == name }) { insertCommand(command) }
                            showingCommands = false
                            model.composerFocus = UUID()
                        }
                    }
            }
        }
    }

    private var sessionControls: some View {
        let session = model.active
        let preferences = session?.preferences
        let modelName = preferences?.selectedModel.flatMap { $0.isEmpty ? nil : $0 }
        let displayed = session?.capabilities?.models.first { $0.value == (modelName ?? "default") }?.displayName ?? modelName ?? session?.model ?? "模型"
        let modes = ["default": "默认权限", "plan": "计划", "acceptEdits": "自动编辑", "dontAsk": "拒绝未授权", "auto": "自动权限"]
        let busy = session?.isBusy ?? false
        return HStack(spacing: 8) {
            if session != nil {
                Button { model.showPreferences = true } label: { Label(modes[preferences?.permissionMode ?? "default"] ?? "默认权限", systemImage: "checkmark.shield") }
                    .buttonStyle(QuietButtonStyle()).foregroundStyle(WorkbenchTheme.inkMuted).disabled(!model.isConnected)
                Spacer(minLength: 12)
                Button { showingModels.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(changingModel ? "切换中…" : (displayed == "Default (recommended)" || displayed == "默认" || displayed == "default") ? "模型：默认" : displayed).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }.buttonStyle(QuietButtonStyle()).disabled(!model.isConnected || changingModel)
                    .popover(isPresented: $showingModels, arrowEdge: .top) {
                        SearchPicker(title: "模型", items: (session?.capabilities?.models ?? []).map {
                            SearchPickerItem(id: $0.value, title: $0.value == "default" ? "远端默认（推荐）" : ($0.displayName ?? $0.value), detail: $0.value == "default" ? "跟随远端 Claude Code 的默认模型" : $0.value)
                        }, selected: modelName ?? "default", refresh: { model.refreshCapabilities(force: true) }) { value in
                            guard let session else { return }
                            showingModels = false
                            changingModel = true
                            Task { @MainActor in
                                defer { changingModel = false }
                                do { try await model.engine?.selectModel(session.id, value == "default" ? "" : value) }
                                catch { model.show(error.localizedDescription) }
                            }
                        }
                    }
            }
            if session == nil { Spacer() }
            HStack(spacing: 8) {
                if busy && canSend {
                    Button { send() } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(ComposerActionStyle())
                        .help("加入队列").accessibilityLabel("加入队列")
                }
                Button { if busy { model.stop() } else { send() } } label: {
                    Image(systemName: busy ? "stop.fill" : "arrow.up")
                }
                .buttonStyle(ComposerActionStyle())
                .help(busy ? "停止生成" : "发送消息 · Enter 发送，Shift + Enter 换行")
                .accessibilityLabel(busy ? "停止生成" : "发送消息")
                .disabled(busy ? session?.status == "stopping" || !model.isConnected : !canSend)
            }

        }
    }

    private func send() {
        guard canSend else { return }
        if model.active == nil {
            let draft = text.wrappedValue
            let source = id
            guard let config = model.currentConfig else { return }
            model.perform {
                guard let engine = model.engine else { return }
                let session = try engine.create(config)
                model.drafts[session.id] = draft
                model.drafts.removeValue(forKey: source)
                model.select(session.id)
                model.submit(text: draft)
            }
        } else { model.submit(text: text.wrappedValue) }
    }

    private func handleKey(_ key: PromptKey) -> Bool {
        if !completions.isEmpty {
            switch key {
            case .up: selection = (selection - 1 + completions.count) % completions.count; return true
            case .down: selection = (selection + 1) % completions.count; return true
            case .tab: choose(completions[min(selection, completions.count - 1)], execute: false); return true
            case .enter: choose(completions[min(selection, completions.count - 1)], execute: true); return true
            case .escape: dismissedText = text.wrappedValue; return true
            }
        }
        if !mentions.isEmpty {
            switch key {
            case .up: selection = (selection - 1 + mentions.count) % mentions.count; return true
            case .down: selection = (selection + 1) % mentions.count; return true
            case .tab, .enter: chooseMention(mentions[min(selection, mentions.count - 1)]); return true
            case .escape: mentions = []; return true
            }
        }
        switch key {
        case .enter: send(); return true
        case .escape:
            if model.active?.isBusy == true { model.stop(); return true }
            return false
        default: return false
        }
    }

    private func insertCommand(_ command: RemoteCommand) {
        if CommandCompletion.token(text.wrappedValue, caret: caret) != nil {
            choose(command, execute: false)
        } else {
            let completed = "/" + command.name + " " + text.wrappedValue
            text.wrappedValue = completed
            dismissedText = completed
            caret = (completed as NSString).length
        }
    }

    private func choose(_ command: RemoteCommand, execute: Bool) {
        guard let token = CommandCompletion.token(text.wrappedValue, caret: caret) else { return }
        let completed = CommandCompletion.complete(text.wrappedValue, stop: token.stop, command: command)
        text.wrappedValue = completed
        dismissedText = completed
        caret = (completed as NSString).length
        if execute { send() }
    }

    private func refreshMentions() {
        mentionTask?.cancel()
        guard let range = mentionRange, let workspace = model.activeWorkspace, model.isConnected else { mentions = []; return }
        let query = String((text.wrappedValue as NSString).substring(with: range).dropFirst())
        mentionTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let found = try? await workspace.suggest(query), !Task.isCancelled else { return }
            mentions = found
            selection = 0
        }
    }

    private func chooseMention(_ file: FileEntry) {
        if let range = mentionRange { text.wrappedValue = (text.wrappedValue as NSString).replacingCharacters(in: range, with: "") }
        mentions = []
        model.attach(file.path)
    }
}
#endif
