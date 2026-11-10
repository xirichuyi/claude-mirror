#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct ChatView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let session = model.active, model.projectMissing(session) {
                    HStack {
                        Label("远端目录已不存在，历史对话仍可查看", systemImage: "folder.badge.questionmark")
                        Spacer()
                        Button("选择项目") { model.showProjectPicker = true }
                    }.font(.callout).padding(12).background(WorkbenchTheme.warning.opacity(0.08))
                }
                if model.active == nil {
                    MachineHomeView()
                } else if let session = model.active, !session.messages.isEmpty || session.remoteHistoryRef != nil {
                    if model.refreshingHistory.contains(session.id) || model.historyRefreshErrors[session.id] != nil || session.historyLoaded == false {
                        HistoryNotice(session: session)
                            .id(session.id)
                            .padding(.horizontal, 24).padding(.vertical, 4)
                            .frame(maxWidth: WorkbenchTheme.conversationWidth, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                    MessagesList(session: session, model: model,
                        historyError: model.historyRefreshErrors[session.id], refreshing: model.refreshingHistory.contains(session.id))
                        .id(session.id)
                } else {
                    WelcomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Reserve real layout space for the composer. A safe-area inset on the
            // outer stack lets the nested native transcript draw behind the input.
            if model.currentConfig != nil {
                ComposerArea()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .background(WorkbenchTheme.canvas)
            }
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
    let session: ChatSession
    // Actions use the model, but unrelated toolbar/draft changes must not invalidate the transcript.
    let model: AppModel
    let historyError: String?
    let refreshing: Bool

    @StateObject private var selection = TranscriptSelection()
    @State private var followsReply = true
    @State private var farFromBottom = false
    @State private var visibleMessageLimit = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
                       session.historyBefore != nil && session.historyLoaded != false,
                       historyError == nil,
                       !refreshing {
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
                    if !session.isBusy, session.historyLoaded != false, session.messages.count == 1,
                       session.messages.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) == "/usage" {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("这条历史记录未保存用量结果", systemImage: "chart.bar").font(.callout.weight(.medium))
                            Text("可直接查看账户当前的五小时与本周用量，无需发送消息。")
                                .font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
                            Button("查看当前用量") { model.presentation = .accountUsage }
                                .buttonStyle(WorkbenchButtonStyle())
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { if #unavailable(macOS 15) { farFromBottom = false } }
                        .onDisappear { if #unavailable(macOS 15) { farFromBottom = true } }
                }
                .environment(\.transcriptSelection, selection)
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: WorkbenchTheme.conversationWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .clipped()
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: "replyViewport")
            .task(id: session.messages.last) {
                // Follow actual message updates, never height estimates produced by scrolling.
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard followsReply else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .modifier(TranscriptScrollTracking(farFromBottom: $farFromBottom, following: $followsReply))
            .overlay(alignment: .bottomTrailing) {
                // AX scrolling does not necessarily emit wheel events. The return
                // control is available whenever the latest message is off screen.
                if farFromBottom {
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
            .onChange(of: session.messages.count) { oldCount, newCount in
                // New replies must not evict the messages the user is reading.
                visibleMessageLimit += max(0, newCount - oldCount)
            }
        }
        }
    }
}

struct HistoryNotice: View {
    @EnvironmentObject private var model: AppModel
    let session: ChatSession
    var loadEarlier: (() -> Void)? = nil
    @State private var showsError = false
    private var refreshing: Bool { model.refreshingHistory.contains(session.id) }

    var body: some View {
        HStack(spacing: 10) {
            if refreshing {
                ProgressView().controlSize(.mini)
                Text(session.historyLoaded == false ? "正在加载历史消息…" : "正在同步最新消息…")
            } else if let error = model.historyRefreshErrors[session.id] {
                HStack(spacing: 2) {
                    Button { showsError.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(WorkbenchTheme.warning)
                            Text("同步失败")
                        }
                        .padding(.leading, 8).padding(.trailing, 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看同步详情")
                    .popover(isPresented: $showsError, arrowEdge: .bottom) {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(WorkbenchTheme.inkMuted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                            .padding(16)
                    }
                    Button { Task { await model.refreshVisibleHistory(session.id) } } label: {
                        WorkbenchIcon(symbol: "arrow.clockwise")
                    }
                    .buttonStyle(WorkbenchIconButtonStyle())
                    .help("重试同步").accessibilityLabel("重试同步")
                    .disabled(!model.isConnected)
                    .padding(.trailing, 2)
                }
                .background(WorkbenchTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            } else if session.historyLoaded == false {
                Text(model.isConnected ? "历史消息尚未加载" : "连接服务器后加载历史消息")
                Spacer()
                Button("加载消息") { model.perform { try await model.engine?.loadHistory(session.id) } }.disabled(!model.isConnected)
            } else if session.historyBefore != nil {
                Button("加载更早消息") {
                    if let loadEarlier { loadEarlier() }
                    else { model.perform { try await model.engine?.loadHistory(session.id, older: true) } }
                }.disabled(session.isBusy || !model.isConnected)
            }
        }.font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).buttonStyle(.borderless)
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
    @State private var hovered = false
    @Environment(\.transcriptSelection) private var selection


    static func == (a: MessageRow, b: MessageRow) -> Bool { a.busy == b.busy && a.sessionStatus == b.sessionStatus && a.showHeader == b.showHeader && a.message == b.message }

    var body: some View {
        Group { if message.role == "user" { userBody } else { assistantBody } }
            .onHover { hovered = $0 }

    }

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let text = message.text, !text.isEmpty {
            SelectableTranscriptText(text: text, markdown: false, scope: selection)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(WorkbenchTheme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
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
                    .background(WorkbenchTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            }
            if let error = message.error {
                ReplyFailureView(error: error, canEdit: model.active?.isBusy != true, edit: restoreRequest)
            }
            if busy && message.error == nil && !hasInlineProgress {
                HStack(spacing: 8) {
                    if sessionStatus == "permission" { Image(systemName: "hand.raised").foregroundStyle(WorkbenchTheme.accent) }
                    else { ProgressView().controlSize(.mini) }
                    Text(message.activity ?? activityLabel).font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
                }.padding(.vertical, 8).accessibilityElement(children: .combine)
            }
            if message.interrupted == true { Text("已停止").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
            if !busy { footer.opacity(hovered || copied ? 1 : 0.25) }
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
                    }.labelStyle(.iconOnly).help(copied ? "已复制" : "复制回复").buttonStyle(WorkbenchIconButtonStyle()).task(id: copied) {
                        if copied { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                    }
                }
                if message.checkpointId != nil && message.error == nil && !isUsageReport {
                    Button { if let checkpoint = message.checkpointId, let id = model.activeId { model.presentation = .rewind(session: id, checkpoint: checkpoint) } } label: { Label("回退文件", systemImage: "arrow.uturn.backward") }.buttonStyle(QuietButtonStyle()).disabled(model.active?.isBusy == true || !model.isConnected)
                }
                Text(parts.joined(separator: " · ")).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted)
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
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(WorkbenchTheme.warning).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(failure.title).font(.system(size: 12, weight: .medium))
                if !failure.isQuotaProtection {
                    Text(failure.summary).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.inkMuted)
                        .lineLimit(expanded ? nil : 2)
                }
                HStack(spacing: 12) {
                    Button(expanded ? "收起" : "详情") { expanded.toggle() }
                    Button("编辑请求", action: edit).disabled(!canEdit)
                    if expanded { Button("复制错误") { copyToPasteboard(error) } }
                }.buttonStyle(.borderless).font(.system(size: 11))
                if expanded {
                    Text(error).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).foregroundStyle(WorkbenchTheme.inkMuted)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
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
        case "thinking":
            if thinkingActive || !(block.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ThinkingCard(text: block.text ?? "", active: thinkingActive)
            }
        case "tool": ToolCard(block: block, actions: actions)
        case "notice":
            Text(block.text ?? "").font(.caption)
                .foregroundStyle(block.level == "error" ? WorkbenchTheme.error : WorkbenchTheme.inkMuted)
                .frame(maxWidth: .infinity, alignment: block.level == "boundary" ? .center : .leading)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { if block.level == "boundary" { Divider() } }
                .overlay(alignment: .bottom) { if block.level == "boundary" { Divider() } }
        default: Text(block.text ?? "暂不支持的消息类型：\(block.type)").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
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
        case "running": return WorkbenchTheme.warning
        case "error": return WorkbenchTheme.error
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
                if let summary = block.summary { Text(summary).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
                if let body = view.body { ToolBodyView(body: body, actions: actions) }
                if let children = block.children, !children.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(children) { child in
                            let step = ToolPresentation(name: child.name, input: child.input)
                            HStack(spacing: 8) {
                                Text(step.title).fontWeight(.medium).foregroundStyle(child.status == "running" ? WorkbenchTheme.warning : child.status == "error" ? WorkbenchTheme.error : Color.primary)
                                Text(step.file ?? step.subject ?? "").foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1)
                            }
                        }
                    }
                    .font(.caption)
                }
                if let text = block.agentText { Text(text).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled) }
                if let output = block.output, !output.isEmpty, !view.hidesOutput || block.status == "error" {
                    CodeBlock(text: output, color: block.status == "error" ? WorkbenchTheme.error : WorkbenchTheme.inkMuted)
                } else if block.name == "Read" {
                    Text(block.status == "running" ? "正在读取…" : block.status == "history" ? "读取结果未保存在历史中" : "无输出")
                        .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
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
                if let subject = view.subject { Text(subject).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1) }
                Spacer(minLength: 4)
                if !statusText.isEmpty { Text(statusText).foregroundStyle(block.status == "error" ? WorkbenchTheme.error : WorkbenchTheme.inkMuted) }
            }
            .font(.caption)
        }
        .padding(.vertical, 2).padding(.horizontal, 2)
        .foregroundStyle(WorkbenchTheme.inkMuted)
    }
}

struct ToolBodyView: View {
    let body_: ToolPresentation.Body
    let actions: FileActions
    init(body: ToolPresentation.Body, actions: FileActions) { body_ = body; self.actions = actions }

    var body: some View {
        switch body_ {
        case .command(let text): CodeBlock(text: text, color: WorkbenchTheme.ink)
        case .code(let text): CodeBlock(text: text, color: WorkbenchTheme.inkMuted)
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
                        .foregroundStyle(item.status == "in_progress" ? WorkbenchTheme.warning : WorkbenchTheme.inkMuted)
                    Text(item.text)
                        .strikethrough(item.status == "completed")
                        .foregroundStyle(item.status == "completed" ? WorkbenchTheme.inkMuted : Color.primary)
                        .fontWeight(item.status == "in_progress" ? .semibold : .regular)
                }
            }
        }
        .font(.callout)
    }
}

struct CodeBlock: View {
    let text: String
    var color: Color = WorkbenchTheme.ink

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 11.5, design: .monospaced)).lineSpacing(3).foregroundStyle(color).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small).strokeBorder(WorkbenchTheme.border))
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
        switch row.kind { case .added: return WorkbenchTheme.added; case .removed: return WorkbenchTheme.removed; case .hunk: return WorkbenchTheme.modified; case .context: return WorkbenchTheme.ink }
    }
    private func rowBackground(_ row: DiffRow) -> Color {
        switch row.kind { case .added: return WorkbenchTheme.added.opacity(0.12); case .removed: return WorkbenchTheme.removed.opacity(0.12); case .hunk: return WorkbenchTheme.modified.opacity(0.08); case .context: return .clear }
    }
}

#endif
