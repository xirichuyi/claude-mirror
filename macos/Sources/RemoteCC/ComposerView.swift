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
                Label(model.connectionState.status == .connecting ? "正在连接…" : "未连接", systemImage: "network.slash")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
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
                    }.font(.caption).foregroundStyle(.secondary)
                }
                PromptEditor(text: text, caret: $caret, placeholder: "发送消息…", handler: handleKey, onPasteImage: { model.pasteImage($0) }, onDropFiles: { model.upload($0) }, acceptsFileDrops: model.isConnected, onFileDrag: { dropTarget = $0 }, focusToken: model.composerFocus, onHeightChange: { editorHeight = $0 })
                    .frame(height: editorHeight)
                toolbarRow
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large).strokeBorder(dropTarget ? WorkbenchTheme.accent : WorkbenchTheme.border))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 2)
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
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
            }

        }
        .padding(.horizontal, 28).padding(.bottom, 14).padding(.top, 6)
        .frame(maxWidth: 820)
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
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        }
    }

    @ViewBuilder private func queue(_ session: ChatSession) -> some View {
        if let queue = session.queue, !queue.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.queuePaused == true ? "队列已暂停" : "回复完成后依次发送").foregroundStyle(.secondary)
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
                    Text((command.description ?? "").components(separatedBy: "\n").first ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(command.argumentHint ?? "").font(.caption2).foregroundStyle(.secondary)
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
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
                    }
                }
            }
        }
    }

    private var toolbarRow: some View {
        let session = model.active
        let preferences = session?.preferences
        let modelName = preferences?.selectedModel.flatMap { $0.isEmpty ? nil : $0 }
        let displayed = session?.capabilities?.models.first { $0.value == (modelName ?? "default") }?.displayName ?? modelName ?? session?.model ?? "模型"
        let modes = ["default": "默认权限", "plan": "计划", "acceptEdits": "自动编辑", "dontAsk": "拒绝未授权", "auto": "自动权限"]
        let busy = session?.isBusy ?? false
        return HStack(spacing: 10) {
            Button { model.pickAndUpload() } label: { Image(systemName: "plus").frame(width: 18, height: 18) }.buttonStyle(QuietButtonStyle()).help("上传文件并附加").disabled(!model.isConnected)
            if session != nil {
                Button { model.openProjectPicker() } label: { Image(systemName: "folder") }.buttonStyle(QuietButtonStyle()).help("切换项目").disabled(!model.isConnected)
                Button { model.showPreferences = true } label: { Label(modes[preferences?.permissionMode ?? "default"] ?? "默认权限", systemImage: "checkmark.shield") }
                    .buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).disabled(!model.isConnected)
                Spacer(minLength: 12)
                Menu {
                    if let session {
                        ForEach(session.capabilities?.models ?? []) { option in
                            Button {
                                changingModel = true
                                Task { @MainActor in
                                    defer { changingModel = false }
                                    do { try await model.engine?.selectModel(session.id, option.value == "default" ? "" : option.value) }
                                    catch { model.show(error.localizedDescription) }
                                }
                            } label: {
                                if option.value == (modelName ?? "default") {
                                    Label(option.displayName ?? option.value, systemImage: "checkmark")
                                } else { Text(option.displayName ?? option.value) }
                            }
                        }
                    }
                    Divider()
                    Button("刷新模型列表") { model.refreshCapabilities(force: true) }
                    Button("自定义模型与更多设置…") { model.showPreferences = true }
                } label: { Text(changingModel ? "切换中…" : displayed == "Default (recommended)" ? "默认" : displayed).font(.caption).lineLimit(1) }
                .menuStyle(.borderlessButton).fixedSize().disabled(!model.isConnected || changingModel)
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

struct MenuList: View {
    let count: Int
    let selection: Int
    let row: (Int) -> AnyView

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        row(index)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(index == selection ? Color.secondary.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
                            .id(index)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            .onChange(of: selection) { proxy.scrollTo(selection) }
        }
    }
}

enum PromptKey { case up, down, tab, enter, escape }

/// NSTextView rather than TextEditor: Enter handling must respect Chinese input-method composition,
/// which only the AppKit text system can report.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int
    let placeholder: String
    let handler: (PromptKey) -> Bool
    let onPasteImage: (Data) -> Void
    let onDropFiles: ([URL]) -> Void
    let acceptsFileDrops: Bool
    let onFileDrag: (Bool) -> Void
    var focusToken: UUID? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let original = scroll.documentView as! NSTextView
        let view = PasteAwareTextView(frame: original.frame, textContainer: original.textContainer)
        view.minSize = original.minSize; view.maxSize = original.maxSize
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = original.autoresizingMask
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes[.paragraphStyle] = paragraph
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        view.delegate = context.coordinator
        view.onContentHeight = onHeightChange
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.onPasteImage = onPasteImage
        view.onDropFiles = onDropFiles
        view.acceptsFileDrops = acceptsFileDrops
        view.onFileDrag = onFileDrag
        view.registerForDraggedTypes([.fileURL])
        scroll.documentView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PasteAwareTextView else { return }
        view.onContentHeight = onHeightChange
        view.onPasteImage = onPasteImage
        view.onDropFiles = onDropFiles
        view.acceptsFileDrops = acceptsFileDrops
        view.onFileDrag = onFileDrag
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        view.needsDisplay = true
        let requestedFocus = context.coordinator.focusToken != focusToken
        if requestedFocus {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        // Never rewrite the text during input-method composition.
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: requestedFocus ? (text as NSString).length : min(caret, (text as NSString).length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var focusToken: UUID?
        init(_ parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.caret = view.selectedRange().location
            parent.text = view.string
            (view as? PasteAwareTextView)?.measureContentHeight()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let location = view.selectedRange().location
            if parent.caret != location { DispatchQueue.main.async { self.parent.caret = location } }
        }
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            // During composition these keys belong to the input method.
            if view.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift) { view.insertNewlineIgnoringFieldEditor(nil); return true }
                return parent.handler(.enter)
            case #selector(NSResponder.moveUp(_:)): return parent.handler(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.handler(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.handler(.tab)
            case #selector(NSResponder.cancelOperation(_:)): return parent.handler(.escape)
            default: return false
            }
        }
    }
}

final class PasteAwareTextView: NSTextView {
    var onContentHeight: ((CGFloat) -> Void)?
    private var lastContentHeight: CGFloat = 0
    override func layout() {
        super.layout()
        measureContentHeight()
    }
    func measureContentHeight() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = min(200, max(40, ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)))
        guard abs(height - lastContentHeight) > 0.5 else { return }
        lastContentHeight = height
        DispatchQueue.main.async { [weak self] in self?.onContentHeight?(height) }
    }
    var onPasteImage: ((Data) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var acceptsFileDrops = false
    var onFileDrag: ((Bool) -> Void)?

    func fileURLs(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender.draggingPasteboard).isEmpty else { return super.draggingEntered(sender) }
        onFileDrag?(acceptsFileDrops)
        return acceptsFileDrops ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender.draggingPasteboard).isEmpty else { return super.draggingUpdated(sender) }
        return acceptsFileDrops ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDrag?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !fileURLs(sender.draggingPasteboard).isEmpty else { return super.prepareForDragOperation(sender) }
        return acceptsFileDrops
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        return acceptFileDrop(urls)
    }

    @discardableResult
    func acceptFileDrop(_ urls: [URL]) -> Bool {
        onFileDrag?(false)
        guard acceptsFileDrops, !urls.isEmpty, urls.allSatisfy(\.isFileURL), let onDropFiles else { return false }
        onDropFiles(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onFileDrag?(false)
        super.concludeDragOperation(sender)
    }
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        // Use the event's modifiers; global modifier state can change before the delegate runs.
        if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.shift) {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let inset = textContainerInset
            (placeholder as NSString).draw(in: NSRect(x: inset.width + (textContainer?.lineFragmentPadding ?? 5), y: inset.height,
                width: max(0, bounds.width - 2 * inset.width - 10), height: bounds.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        // Text wins when both exist, so copied rich text is not uploaded as a picture.
        if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        super.paste(sender)
    }
}

struct PermissionCard: View {
    @EnvironmentObject private var model: AppModel
    let permission: PermissionRequest
    var onAnswer: ((JSON) async throws -> Void)? = nil
    @State private var answers: [String: String] = [:]
    @State private var reason = ""
    @State private var useRules = false
    @State private var sending = false
    @State private var error = ""
    @State private var form: [String: JSON] = [:]

    private var actions: FileActions { FileActions(open: { model.open($0, line: $1) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("等待你的确认", systemImage: "hand.raised.fill").foregroundStyle(WorkbenchTheme.accent)
                Spacer()
                if sending { ProgressView().controlSize(.mini); Text("正在提交…").foregroundStyle(.secondary) }
            }.font(.subheadline.weight(.medium)).padding(.bottom, 4)
            if permission.kind == "elicitation" { elicitation } else { approval }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .disabled(sending || (onAnswer == nil && !model.isConnected))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).stroke(WorkbenchTheme.accent.opacity(0.25)))
        .font(.callout)
    }

    private func submit(_ answer: JSON) {
        sending = true; error = ""
        Task {
            do {
                if let onAnswer { try await onAnswer(answer) }
                else { try await model.respond(permission, answer: answer) }
            }
            catch { self.error = error.localizedDescription; sending = false }
        }
    }

    @ViewBuilder private var approval: some View {
        let question = permission.name == "AskUserQuestion"
        let view = ToolPresentation(name: permission.name, input: permission.input)
        Text(question ? "Claude 想确认一下" : permission.name == "ExitPlanMode" ? "Claude 的计划，确认后开始执行" : permission.title ?? "Claude 请求使用 \(permission.name ?? "工具")").fontWeight(.semibold)
        if let description = permission.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if question { questions }
                else {
                    if let file = view.file { Button(file) { model.open(file) }.buttonStyle(.link) }
                    if let subject = view.subject, permission.name != "Bash" { Text(subject).foregroundStyle(.secondary) }
                    if let body = view.body { ToolBodyView(body: body, actions: actions) }
                    else if view.file == nil && view.subject == nil { CodeBlock(text: permission.input?.text(pretty: true) ?? "") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
        if let suggestions = permission.suggestions?.array, !suggestions.isEmpty {
            DisclosureGroup("远端建议的权限规则") { CodeBlock(text: permission.suggestions?.text(pretty: true) ?? "") }.font(.caption)
            Toggle("应用以上权限规则 · " + scope(suggestions), isOn: $useRules).font(.caption)
        }
        TextField(permission.name == "ExitPlanMode" ? "对计划的修改意见" : "拒绝时给 Claude 的说明（可选）", text: $reason).textFieldStyle(.roundedBorder).font(.caption)
        HStack {
            Spacer()
            if permission.name == "ExitPlanMode" {
                Button("反馈修改意见") { submit(["allow": false, "reason": .string(reason)]) }
                    .buttonStyle(WorkbenchButtonStyle()).disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("拒绝") { submit(["allow": false, "reason": .string(reason)]) }.buttonStyle(WorkbenchButtonStyle())
            Button(question ? "提交回答" : useRules ? "应用规则并允许" : "允许这一次") { allow() }.buttonStyle(WorkbenchButtonStyle(prominent: true))
        }
        .disabled(sending)
    }

    private func allow() {
        var answer: JSON = ["allow": true, "useSuggestedPermissions": .bool(useRules)]
        if permission.name == "AskUserQuestion" {
            let list = (permission.input?["questions"]?.array ?? []).compactMap { $0["question"]?.string }
            if list.contains(where: { (answers[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) { error = "请填写回答"; return }
            answer["answers"] = .object(answers.mapValues(JSON.string))
        }
        submit(answer)
    }

    private func scope(_ suggestions: [JSON]) -> String {
        let names = ["session": "本次运行", "localSettings": "此项目的本地设置", "projectSettings": "此项目的共享设置", "userSettings": "远端用户的所有项目", "cliArg": "本次启动参数"]
        var seen: [String] = []
        for destination in suggestions.compactMap({ $0["destination"]?.string }) {
            let name = names[destination] ?? destination
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.joined(separator: "、")
    }

    @ViewBuilder private var questions: some View {
        ForEach(permission.input?["questions"]?.array ?? [], id: \.self) { item in
            if let question = item["question"]?.string {
                VStack(alignment: .leading, spacing: 5) {
                    Text(question)
                    TextField("输入你的回答，也可选择下方建议", text: Binding(get: { answers[question] ?? "" }, set: { answers[question] = $0 })).textFieldStyle(.roundedBorder)
                    FlowOptions(options: (item["options"]?.array ?? []).compactMap { option in option["label"]?.string.map { ($0, option["description"]?.string ?? "") } }, selected: selectedOptions(question), toggle: { toggle($0, question: question, multiple: item["multiSelect"]?.isTruthy == true) })
                }
            }
        }
    }

    private func selectedOptions(_ question: String) -> Set<String> {
        Set((answers[question] ?? "").components(separatedBy: ", "))
    }

    private func toggle(_ label: String, question: String, multiple: Bool) {
        guard multiple else { answers[question] = label; return }
        var chosen = (answers[question] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }
        if let index = chosen.firstIndex(of: label) { chosen.remove(at: index) } else { chosen.append(label) }
        answers[question] = chosen.joined(separator: ", ")
    }

    @ViewBuilder private var elicitation: some View {
        let request = permission.request
        Text(request?["title"]?.string ?? "需要你的输入").fontWeight(.semibold)
        if let server = request?["serverName"]?.string { Text(server).font(.caption2).foregroundStyle(.secondary) }
        if let message = request?["message"]?.string { Text(message).textSelection(.enabled) }
        if request?["mode"]?.string == "url", let link = request?["url"]?.string, let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") {
            Text(link).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            // Opening is the user's click; it is not treated as proof that authorization succeeded.
            Button("打开 " + (url.host ?? link)) { NSWorkspace.shared.open(url) }
            actionRow(acceptTitle: "已完成，继续", supported: true) { ["action": "accept"] }
        } else if let fields = try? SchemaField.fields(request?["requestedSchema"]) {
            ForEach(fields) { field in SchemaFieldView(field: field, values: $form) }
            actionRow(acceptTitle: "提交", supported: true) { ["action": "accept", "content": .object(form)] }
        } else {
            Text("此表单包含暂不支持的结构，可以拒绝或取消。").font(.caption).foregroundStyle(.secondary)
            actionRow(acceptTitle: "提交", supported: false) { ["action": "accept"] }
        }
    }

    private func actionRow(acceptTitle: String, supported: Bool, accept: @escaping () -> JSON) -> some View {
        HStack {
            Spacer()
            Button("取消") { submit(["interaction": ["action": "cancel"]]) }
            Button("拒绝") { submit(["interaction": ["action": "decline"]]) }
            Button(acceptTitle) { submit(["interaction": accept()]) }.buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(!supported)
        }
        .disabled(sending)
    }
}

struct FlowOptions: View {
    let options: [(String, String)]
    let selected: Set<String>
    let toggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(options, id: \.0) { option in
                    Button(option.0) { toggle(option.0) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(selected.contains(option.0) ? Color.accentColor : Color.secondary)
                        .help(option.1)
                }
            }
        }
    }
}

struct SchemaFieldView: View {
    let field: SchemaField
    @Binding var values: [String: JSON]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch field.kind {
            case .boolean:
                Toggle(field.label, isOn: Binding(get: { values[field.name]?.bool ?? field.defaultValue?.bool ?? false }, set: { values[field.name] = .bool($0) }))
                    .onAppear { if values[field.name] == nil { values[field.name] = .bool(field.defaultValue?.bool ?? false) } }
            case .choice:
                Picker(field.label, selection: Binding(get: { values[field.name]?.string ?? "" }, set: { values[field.name] = .string($0) })) {
                    Text("请选择").tag("")
                    ForEach(field.options) { Text($0.label).tag($0.value) }
                }
                .onAppear { if let value = field.defaultValue, values[field.name] == nil { values[field.name] = value } }
            case .multiChoice:
                Text(field.label)
                ForEach(field.options) { option in
                    Toggle(option.label, isOn: Binding(get: { (values[field.name]?.array ?? []).contains(.string(option.value)) }, set: { on in
                        var list = values[field.name]?.array ?? []
                        list.removeAll { $0 == .string(option.value) }
                        if on { list.append(.string(option.value)) }
                        values[field.name] = .array(list)
                    }))
                }
            case .number, .integer:
                TextField(field.label, text: Binding(get: { values[field.name]?.double.map { field.kind == .integer ? String(Int($0)) : String($0) } ?? "" }, set: { text in
                    // An empty field means no answer, which the worker checks against `required`.
                    values[field.name] = Double(text).map(JSON.number)
                })).textFieldStyle(.roundedBorder)
            case .text:
                TextField(field.label, text: Binding(get: { values[field.name]?.string ?? field.defaultValue?.string ?? "" }, set: { values[field.name] = .string($0) })).textFieldStyle(.roundedBorder)
            }
            if let description = field.description { Text(description).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
#endif
