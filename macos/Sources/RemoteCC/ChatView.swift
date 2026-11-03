#if canImport(SwiftUI)
import SwiftUI
import MarkdownUI
import AppKit
import RemoteCCCore

struct ChatView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.active, model.projectMissing(session) {
                HStack {
                    Label("远端目录已不存在，历史对话仍可查看", systemImage: "folder.badge.questionmark")
                    Spacer()
                    Button("选择项目") { model.showProjectPicker = true }
                }.font(.callout).padding(12).background(Color.orange.opacity(0.08))
            }
            if model.active == nil {
                MachineHomeView()
            } else if let session = model.active, !session.messages.isEmpty || session.remoteHistoryRef != nil {
                MessagesList(session: session).id(session.id)
            } else {
                WelcomeView()
            }
            if model.currentConfig != nil { ComposerArea() }
        }
        .background(WorkbenchTheme.canvas)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            VStack(spacing: 28) {
                HStack(spacing: 12) {
                    BrandIcon(size: 38)
                    Text("今天，想完成什么？")
                        .font(.title.weight(.medium))
                }
                HStack(spacing: 8) {
                    suggestion("了解项目", icon: "folder", prompt: "请梳理这个项目的目录结构、技术栈和主要入口。")
                    suggestion("检查代码", icon: "text.magnifyingglass", prompt: "请检查当前项目，找出影响使用的问题并给出改进建议。")
                    suggestion("实现功能", icon: "chevron.left.forwardslash.chevron.right", prompt: "我想实现一个新功能：")
                }
                .opacity((model.drafts[model.activeId ?? "welcome"] ?? "").isEmpty ? 1 : 0)
                .disabled(!(model.drafts[model.activeId ?? "welcome"] ?? "").isEmpty)
                .accessibilityHidden(!(model.drafts[model.activeId ?? "welcome"] ?? "").isEmpty)
            }
            .frame(maxWidth: 600).padding(.horizontal, 36)
            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestion(_ title: String, icon: String, prompt: String) -> some View {
        Button { model.drafts[model.activeId ?? "welcome"] = prompt; model.composerFocus = UUID() } label: {
            Label(title, systemImage: icon).font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(WorkbenchTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
        }.buttonStyle(.plain)
    }
}

struct MessagesList: View {
    @EnvironmentObject private var model: AppModel
    let session: ChatSession
    @StateObject private var selection = TranscriptSelection()
    @State private var followsReply = true
    @State private var bottomDistance: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var visibleMessageLimit = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if session.messages.count > visibleMessageLimit {
                        Button("加载更早消息") {
                            let anchor = session.messages.suffix(visibleMessageLimit).first?.id
                            followsReply = false
                            visibleMessageLimit += 50
                            Task { @MainActor in
                                await Task.yield()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        }
                            .font(.caption)
                    }
                    if session.remoteHistoryRef != nil,
                       session.historyLoaded == false || session.historyBefore != nil || model.refreshingHistory.contains(session.id) || model.historyRefreshErrors[session.id] != nil {
                        HistoryNotice(session: session) {
                            followsReply = false
                            let anchor = session.messages.first?.id
                            model.perform {
                                try await model.engine?.loadHistory(session.id, older: true)
                                // Keep the first previously visible message in place after prepending.
                                await Task.yield()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        }
                    }
                    ForEach(Array(session.messages.enumerated().suffix(visibleMessageLimit)), id: \.element.id) { index, message in
                        // Equatable lets unchanged messages skip rendering while the last one streams.
                        MessageRow(message: message, busy: index == session.messages.count - 1 && session.isBusy, sessionStatus: session.status, showHeader: index == 0 || session.messages[index - 1].role != "assistant", actions: FileActions(open: { model.open($0, line: $1) }))
                            .equatable()
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .environment(\.transcriptSelection, selection)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: WorkbenchTheme.conversationWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { content in
                    Color.clear.preference(key: ReplyBottomPreference.self,
                        value: ReplyGeometry(height: content.size.height, bottom: content.frame(in: .named("replyViewport")).maxY))
                })
            }
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: "replyViewport")
            .onPreferenceChange(ReplyBottomPreference.self) { geometry in
                // Offset changes only update the jump button. Never scroll from an offset
                // callback: scrolling changes the offset again and creates a layout loop.
                bottomDistance = max(0, geometry.bottom - viewport.size.height)
                contentHeight = geometry.height
            }
            .task(id: contentHeight) {
                // Coalesce streamed text and wait for native text measurement to settle.
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard followsReply else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .background(ScrollReadingDetector { followsReply = false })
            .overlay(alignment: .bottomTrailing) {
                if ReplyScrollPolicy.showsJump(distance: Double(bottomDistance), following: followsReply) {
                    Button {
                        followsReply = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.system(size: 14, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(WorkbenchTheme.surface, in: Circle())
                            .overlay(Circle().strokeBorder(WorkbenchTheme.border))
                    }.buttonStyle(.plain).help("回到最新").accessibilityLabel("回到最新")
                        .shadow(color: .black.opacity(0.06), radius: 5, y: 2).padding(16)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: followsReply) { if followsReply { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: session.messages.count) { oldCount, newCount in
                // New replies must not evict the messages the user is reading.
                visibleMessageLimit += max(0, newCount - oldCount)
            }
        }
        }
    }
}

private struct ReplyGeometry: Equatable {
    var height: CGFloat = 0
    var bottom: CGFloat = 0
}
private struct ReplyBottomPreference: PreferenceKey {
    static var defaultValue = ReplyGeometry()
    static func reduce(value: inout ReplyGeometry, nextValue: () -> ReplyGeometry) { value = nextValue() }
}

struct HistoryNotice: View {
    @EnvironmentObject private var model: AppModel
    let session: ChatSession
    var loadEarlier: (() -> Void)? = nil

    var body: some View {
        HStack {
            if let error = model.historyRefreshErrors[session.id] { Text(error).foregroundStyle(.orange) }
            if model.refreshingHistory.contains(session.id) { ProgressView().controlSize(.mini) }
            if session.historyLoaded == false {
                Button("加载消息") { model.perform { try await model.engine?.loadHistory(session.id) } }
            } else if session.historyBefore != nil {
                Button("加载更早消息") {
                    if let loadEarlier { loadEarlier() }
                    else { model.perform { try await model.engine?.loadHistory(session.id, older: true) } }
                }.disabled(session.isBusy)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Closures are not comparable, so they are left out of MessageRow's equality.
struct FileActions {
    let open: (String, Int?) -> Void
}

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let busy: Bool
    var sessionStatus: String = "idle"
    var showHeader = true
    let actions: FileActions
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    @Environment(\.transcriptSelection) private var selection
    @State private var showRewind = false

    static func == (a: MessageRow, b: MessageRow) -> Bool { a.busy == b.busy && a.sessionStatus == b.sessionStatus && a.showHeader == b.showHeader && a.message == b.message }

    var body: some View {
        Group { if message.role == "user" { userBody } else { assistantBody } }
            .sheet(isPresented: $showRewind) {
                if let checkpoint = message.checkpointId, let id = model.activeId { RewindSheet(sessionId: id, checkpoint: checkpoint).workbenchPanel() }
            }
    }

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let text = message.text, !text.isEmpty {
            SelectableTranscriptText(text: text, markdown: false, scope: selection)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(WorkbenchTheme.userBubble, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large))
            }
            if let files = message.attachments {
                ForEach(files) { file in
                    ChatAttachmentView(file: file)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((message.blocks ?? []).enumerated()).filter { !isDuplicateError($0.element) }, id: \.offset) { index, block in
                BlockView(block: block, actions: actions, thinkingActive: busy && sessionStatus == "working" && index == (message.blocks?.count ?? 0) - 1)
            }
            if let issue = message.serviceIssue {
                VStack(alignment: .leading, spacing: 6) {
                    Label(issue["title"]?.string ?? "服务暂不可用", systemImage: "exclamationmark.circle").font(.body.weight(.medium))
                    Text(issue["detail"]?.string ?? "").font(.callout).textSelection(.enabled)
                    if let reset = issue["resetsAt"]?.double {
                        Text("预计恢复：" + Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            }
            if let error = message.error {
                ReplyFailureView(error: error, canEdit: model.active?.isBusy != true, edit: restoreRequest)
            }
            if busy && message.error == nil && !hasInlineProgress {
                HStack(spacing: 8) {
                    if sessionStatus == "permission" { Image(systemName: "hand.raised").foregroundStyle(WorkbenchTheme.accent) }
                    else { ProgressView().controlSize(.mini) }
                    Text(message.activity ?? activityLabel).font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 8).accessibilityElement(children: .combine)
            }
            if message.interrupted == true { Text("已停止").font(.caption).foregroundStyle(.secondary) }
            if !busy { footer }
        }
    }

    private func isDuplicateError(_ block: Block) -> Bool {
        message.error.map { ReplyFailure($0).duplicates(block) } ?? false
    }

    private var hasInlineProgress: Bool {
        guard sessionStatus == "working", let last = message.blocks?.last else { return false }
        return last.type == "thinking" || (last.type == "tool" && last.status == "running")
    }

    private var activityLabel: String {
        if sessionStatus == "permission" { return "等待确认" }
        if sessionStatus == "stopping" { return "正在停止…" }
        if sessionStatus == "detached" { return "等待重新连接…" }
        if message.blocks?.contains(where: { $0.type == "tool" && $0.status == "running" }) == true { return "正在执行工具…" }
        if message.blocks?.last?.type == "thinking" { return "正在思考…" }
        return (message.blocks ?? []).isEmpty ? "等待 Claude 响应…" : "正在生成回复…"
    }

    private func restoreRequest() {
        guard let session = model.active,
              let index = session.messages.firstIndex(where: { $0.id == message.id }),
              let request = session.messages[..<index].last(where: { $0.role == "user" }) else { return }
        guard (model.drafts[session.id] ?? "").isEmpty, (model.attachments[session.id] ?? []).isEmpty else {
            model.show("输入框已有草稿，请先保留或发送草稿后再重新编辑。"); return
        }
        model.drafts[session.id] = request.text ?? ""
        model.attachments[session.id] = request.attachments ?? []
        model.composerFocus = UUID()
    }

    @ViewBuilder private var footer: some View {
        let text = (message.blocks ?? []).filter { $0.type == "text" && !isDuplicateError($0) }.compactMap(\.text).joined(separator: "\n\n")
        let isUsageReport = (message.blocks ?? []).contains { UsageReport($0.text ?? "") != nil }
        let parts = isUsageReport ? [] : [message.model, message.durationMs.map { String(format: "%.1fs", $0 / 1000) }, message.costUSD.map { String(format: "$%.4f", $0) }].compactMap { $0 }
        if !text.isEmpty || !parts.isEmpty || message.checkpointId != nil {
            HStack(spacing: 10) {
                if !text.isEmpty {
                    Button { copyToPasteboard(text); copied = true } label: {
                        Label(copied ? "已复制" : "复制回复", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.labelStyle(.iconOnly).help(copied ? "已复制" : "复制回复").buttonStyle(QuietButtonStyle()).task(id: copied) {
                        if copied { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                    }
                }
                if message.checkpointId != nil && message.error == nil && !isUsageReport {
                    Button { showRewind = true } label: { Label("回退文件", systemImage: "arrow.uturn.backward") }.buttonStyle(QuietButtonStyle()).disabled(model.active?.isBusy == true || !model.isConnected)
                }
                Text(parts.joined(separator: " · ")).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct ReplyFailureView: View {
    let error: String
    let canEdit: Bool
    let edit: () -> Void
    @State private var expanded = false

    var body: some View {
        let failure = ReplyFailure(error)
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.title, systemImage: "exclamationmark.circle")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
            Text(failure.summary).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
            HStack(spacing: 12) {
                Button("编辑请求", action: edit).disabled(!canEdit)
                Button(expanded ? "收起详情" : "查看详情") { expanded.toggle() }
                if expanded { Button("复制错误") { copyToPasteboard(error) } }
            }.buttonStyle(.borderless).font(.caption)
            if expanded {
                Text(error).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(WorkbenchTheme.border))
    }
}

struct BlockView: View {
    let block: Block
    let actions: FileActions
    var thinkingActive = false

    var body: some View {
        switch block.type {
        case "text":
            if let report = UsageReport(block.text ?? "") {
                UsageReportView(report: report)
            } else if block.format == "command" {
                Text(block.text ?? "").font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            } else { MarkdownView(text: block.text ?? "", actions: actions) }
        case "thinking": ThinkingCard(text: block.text ?? "", active: thinkingActive)
        case "tool": ToolCard(block: block, actions: actions)
        case "notice":
            Text(block.text ?? "").font(.caption)
                .foregroundStyle(block.level == "error" ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: block.level == "boundary" ? .center : .leading)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { if block.level == "boundary" { Divider() } }
                .overlay(alignment: .bottom) { if block.level == "boundary" { Divider() } }
        default: Text(block.text ?? "暂不支持的消息类型：\(block.type)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ToolCard: View {
    @EnvironmentObject private var model: AppModel
    let block: Block
    let actions: FileActions
    @State private var expanded: Bool?

    private var presentation: ToolPresentation { ToolPresentation(name: block.name, input: block.input) }
    private var isOpen: Binding<Bool> {
        Binding(get: { expanded ?? (block.status == "error") }, set: { expanded = $0 })
    }
    private var dotColor: Color {
        switch block.status {
        case "running": return .orange
        case "error": return .red
        case "stopped", "history": return .gray
        default: return WorkbenchTheme.sage
        }
    }
    private var statusText: String {
        if block.status == "running" { return block.elapsed.map { "\(Int($0))s" } ?? "执行中" }
        if ["history", "done"].contains(block.status ?? "") { return "" }
        return ["error": "失败", "stopped": "已停止"][block.status ?? ""] ?? "待执行"
    }

    var body: some View {
        let view = presentation
        DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if let file = view.file, ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"].contains(block.name ?? "") {
                    HStack {
                        Button("打开文件") { actions.open(file, view.line) }
                        Button("下载") { model.download(file) }
                        if block.name != "Read" { Button("查看变更") { model.panel = .changes; model.showFiles = true } }
                    }.font(.caption).disabled(!model.isConnected)
                }
                if let summary = block.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                if let body = view.body { ToolBodyView(body: body, actions: actions) }
                if let children = block.children, !children.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(children) { child in
                            let step = ToolPresentation(name: child.name, input: child.input)
                            HStack(spacing: 8) {
                                Text(step.title).fontWeight(.medium).foregroundStyle(child.status == "running" ? Color.orange : child.status == "error" ? Color.red : Color.primary)
                                Text(step.file ?? step.subject ?? "").foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .font(.caption)
                }
                if let text = block.agentText { Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let output = block.output, !output.isEmpty, !view.hidesOutput || block.status == "error" {
                    CodeBlock(text: output, color: block.status == "error" ? .red : .secondary)
                } else if block.name == "Read" {
                    Text(block.status == "running" ? "正在读取…" : block.status == "history" ? "读取结果未保存在历史中" : "无输出")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 7) {
                if block.status == "running" { ProgressView().controlSize(.mini) }
                else { Image(systemName: block.status == "error" ? "xmark.circle" : block.status == "done" ? "checkmark.circle" : "terminal").foregroundStyle(dotColor) }
                Text(view.title).fontWeight(.medium)
                if let file = view.file {
                    Button((file as NSString).lastPathComponent) { actions.open(file, view.line) }.buttonStyle(.link).lineLimit(1).truncationMode(.middle).help(file)
                }
                if let subject = view.subject { Text(subject).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                if !statusText.isEmpty { Text(statusText).foregroundStyle(block.status == "error" ? Color.red : Color.secondary) }
            }
            .font(.caption)
        }
        .padding(.vertical, 2).padding(.horizontal, 2)
        .foregroundStyle(.secondary)
    }
}

struct ToolBodyView: View {
    let body_: ToolPresentation.Body
    let actions: FileActions
    init(body: ToolPresentation.Body, actions: FileActions) { body_ = body; self.actions = actions }

    var body: some View {
        switch body_ {
        case .command(let text): CodeBlock(text: text, color: .primary)
        case .code(let text): CodeBlock(text: text, color: .secondary)
        case .diff(let rows): DiffView(rows: rows, maxHeight: 420)
        case .markdown(let text): MarkdownView(text: text, actions: actions)
        case .todos(let items): TodoList(items: items)
        }
    }
}

struct TodoList: View {
    let items: [TodoItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                        .foregroundStyle(item.status == "in_progress" ? Color.orange : Color.secondary)
                    Text(item.text)
                        .strikethrough(item.status == "completed")
                        .foregroundStyle(item.status == "completed" ? Color.secondary : Color.primary)
                        .fontWeight(item.status == "in_progress" ? .semibold : .regular)
                }
            }
        }
        .font(.callout)
    }
}

struct CodeBlock: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(color).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
    }
}

struct DiffView: View {
    let rows: [DiffRow]
    var maxHeight: CGFloat? = nil

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(prefix(row) + row.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(foreground(row))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowBackground(row))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: maxHeight)
    }
    private func prefix(_ row: DiffRow) -> String {
        switch row.kind { case .added: return "+ "; case .removed: return "- "; case .context: return "  "; case .hunk: return "" }
    }
    private func foreground(_ row: DiffRow) -> Color {
        switch row.kind { case .added: return .green; case .removed: return .red; case .hunk: return .blue; case .context: return .primary }
    }
    private func rowBackground(_ row: DiffRow) -> Color {
        switch row.kind { case .added: return .green.opacity(0.1); case .removed: return .red.opacity(0.1); case .hunk: return .blue.opacity(0.06); case .context: return .clear }
    }
}

struct MarkdownView: View {
    let text: String
    let actions: FileActions
    @Environment(\.transcriptSelection) private var selection

    var body: some View {
        SelectableTranscriptText(text: text, scope: selection) { url in
            if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            else if let reference = RemoteFileLinks.reference(url) { actions.open(reference.path, reference.line) }
        }
    }
}
#endif
