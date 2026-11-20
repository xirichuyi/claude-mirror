#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RemoteCCCore

/// One request from the remote Claude that waits for the user: a tool approval, an
/// AskUserQuestion, a plan, or an MCP form. The application presentation layer supplies
/// the shared dialog surface; this view supplies its heading, fields and actions.
struct PermissionCard: View {
    @EnvironmentObject private var model: AppModel
    let permission: PermissionRequest
    /// The session the request belongs to; answers go there even if another chat is opened meanwhile.
    var sessionId: String? = nil
    /// How many requests are waiting in total, this one included.
    var pending = 1
    var onDefer: (() -> Void)? = nil
    var onAnswer: ((JSON) async throws -> Void)? = nil
    @State private var answers: [String: QuestionAnswer] = [:]
    @State private var reason = ""
    @State private var useRules = false
    @State private var showRawRules = false
    @State private var sending = false
    @State private var error = ""
    @State private var form: [String: JSON] = [:]

    private var actions: FileActions { FileActions(open: { model.open($0, line: $1) }) }
    private var offline: Bool { onAnswer == nil && !model.isConnected }
    private var isQuestion: Bool { permission.name == "AskUserQuestion" }
    private var isPlan: Bool { permission.name == "ExitPlanMode" }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchTheme.Space.m) {
            header
            Group {
                if permission.kind == "elicitation" { elicitation } else { approval }
            }.disabled(sending || offline)
        }
        .padding(WorkbenchTheme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workbenchPanel()
        .task(id: sending) {
            // The card disappears once the remote clears the request. If that never arrives, let the
            // user retry instead of leaving a spinner forever; the server rejects stale duplicates.
            guard sending else { return }
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, sending else { return }
            sending = false
            error = "已提交，但远端还没有确认。可以稍等，或再提交一次。"
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onDefer {
                SheetHeading(title: headline, subtitle: detail ?? "", closeTitle: "稍后处理", close: onDefer)
            } else {
                Text(headline).font(.system(size: 14, weight: .semibold))
                if let detail { Text(detail).font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
            }
            if pending > 1 {
                Text("还有 \(pending - 1) 项待确认").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            }
        }
    }

    private var headline: String {
        if permission.kind == "elicitation" { return permission.request?["title"]?.string ?? "需要你的输入" }
        if isQuestion { return "Claude 想确认几个问题" }
        if isPlan { return "Claude 的计划，确认后开始执行" }
        return permission.title ?? "Claude 请求使用 \(permission.name ?? "工具")"
    }

    private var detail: String? {
        if permission.kind == "elicitation" { return permission.request?["serverName"]?.string.map { "来自 MCP 服务 " + $0 } }
        let description = permission.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tool = isQuestion || isPlan ? nil : permission.name
        let parts = [tool, description.isEmpty ? nil : description].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Status on the left, actions on the right, separated from the content by a hairline.
    private func footer<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        VStack(spacing: WorkbenchTheme.Space.m) {
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            HStack(spacing: 8) {
                if sending {
                    ProgressView().controlSize(.mini)
                    Text("正在提交…").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                } else if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.error)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else if offline {
                    Label("未连接，连接后才能回答", systemImage: "network.slash").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                Spacer(minLength: 8)
                if let onDefer { Button("稍后处理", action: onDefer).buttonStyle(WorkbenchButtonStyle()) }
                actions()
            }
        }
    }

    private func submit(_ answer: JSON) {
        sending = true; error = ""
        Task {
            do {
                if let onAnswer { try await onAnswer(answer) }
                else { try await model.respond(permission, answer: answer, session: sessionId) }
            }
            catch { self.error = error.localizedDescription; sending = false }
        }
    }

    // MARK: Tool approval, question, plan

    @ViewBuilder private var approval: some View {
        let view = ToolPresentation(name: permission.name, input: permission.input)
        if isQuestion {
            questions
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let file = view.file {
                    Button { model.open(file) } label: {
                        Label(file, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                    }.buttonStyle(.link).font(WorkbenchMetrics.caption)
                }
                if let subject = view.subject, permission.name != "Bash" {
                    Text(subject).font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled)
                }
                if let body = view.body {
                    ScrollView { ToolBodyView(body: body, actions: actions).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true)
                } else if view.file == nil && view.subject == nil {
                    CodeBlock(text: permission.input?.text(pretty: true) ?? "")
                }
            }
        }
        rules
        if !isQuestion {
            TextField(isPlan ? "对计划的修改意见（反馈时发给 Claude）" : "补充说明（可选，拒绝时发给 Claude）", text: $reason)
                .textFieldStyle(WorkbenchTextFieldStyle())
        }
        footer {
            if isPlan {
                Button("反馈修改意见") { submit(["allow": false, "reason": .string(reason)]) }
                    .buttonStyle(WorkbenchButtonStyle())
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("拒绝") { submit(["allow": false, "reason": .string(reason)]) }.buttonStyle(WorkbenchButtonStyle())
            Button(isQuestion ? "提交回答" : isPlan ? "开始执行" : useRules ? "允许并应用规则" : "允许这一次") { allow() }
                .buttonStyle(WorkbenchButtonStyle(prominent: true))
        }
    }

    /// The remote's suggested rules in words, with the raw updates one click away.
    @ViewBuilder private var rules: some View {
        let lines = PermissionRules.lines(permission.suggestions)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $useRules) {
                    Text("同时应用以下权限规则").foregroundStyle(WorkbenchTheme.ink)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            WorkbenchIcon(symbol: line.widens ? "checkmark.shield" : "shield")
                                .foregroundStyle(line.widens ? WorkbenchTheme.warning : WorkbenchTheme.inkMuted)
                            Text(line.action).foregroundStyle(WorkbenchTheme.ink).textSelection(.enabled)
                            Text("· " + line.scope).foregroundStyle(WorkbenchTheme.inkMuted)
                        }
                    }
                    Button(showRawRules ? "隐藏原始规则" : "查看原始规则") { showRawRules.toggle() }
                        .buttonStyle(.link).font(.system(size: 11))
                    if showRawRules { CodeBlock(text: permission.suggestions?.text(pretty: true) ?? "", color: WorkbenchTheme.inkMuted) }
                }
                .font(WorkbenchMetrics.caption)
                .padding(.leading, 24)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium, style: .continuous)
                .strokeBorder(useRules ? WorkbenchTheme.accent.opacity(0.6) : WorkbenchTheme.border))
        }
    }

    private func allow() {
        var answer: JSON = ["allow": true, "useSuggestedPermissions": .bool(useRules)]
        if isQuestion {
            let list = questionItems.compactMap { $0["question"]?.string }
            if list.contains(where: { (answers[$0] ?? QuestionAnswer()).text.isEmpty }) { error = "每个问题都需要回答"; return }
            answer["answers"] = .object(list.reduce(into: [String: JSON]()) { result, question in
                result[question] = .string(answers[question]?.text ?? "")
            })
        }
        submit(answer)
    }

    private var questionItems: [JSON] { permission.input?["questions"]?.array ?? [] }

    @ViewBuilder private var questions: some View {
        VStack(alignment: .leading, spacing: WorkbenchTheme.Space.m) {
            ForEach(Array(questionItems.enumerated()), id: \.offset) { index, item in
                if let question = item["question"]?.string {
                    let multiple = item["multiSelect"]?.isTruthy == true
                    let answer = Binding(get: { answers[question] ?? QuestionAnswer() }, set: { answers[question] = $0 })
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if questionItems.count > 1 { Text("\(index + 1).").foregroundStyle(WorkbenchTheme.inkMuted).monospacedDigit() }
                            Text(question).foregroundStyle(WorkbenchTheme.ink).fixedSize(horizontal: false, vertical: true)
                            if multiple { Text("可多选").font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted) }
                        }
                        WorkbenchChoiceList(options: (item["options"]?.array ?? []).compactMap { option in option["label"]?.string.map { ($0, option["description"]?.string ?? "") } },
                                    selected: Set(answer.wrappedValue.picked),
                                    toggle: { answers[question, default: QuestionAnswer()].toggle($0, multiple: multiple) })
                        TextField("或者直接写下你的回答", text: answer.typed).textFieldStyle(WorkbenchTextFieldStyle())
                    }
                }
            }
        }
    }

    // MARK: MCP form (elicitation)

    @ViewBuilder private var elicitation: some View {
        let request = permission.request
        if let message = request?["message"]?.string { Text(message).foregroundStyle(WorkbenchTheme.ink).textSelection(.enabled) }
        if request?["mode"]?.string == "url", let link = request?["url"]?.string, let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") {
            HStack(spacing: 8) {
                Text(link).font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                // Opening is the user's click; it is not treated as proof that authorization succeeded.
                Button("打开 " + (url.host ?? link)) { NSWorkspace.shared.open(url) }.buttonStyle(WorkbenchButtonStyle())
            }
            actionRow(acceptTitle: "已完成，继续", supported: true) { ["action": "accept"] }
        } else if let fields = try? SchemaField.fields(request?["requestedSchema"]) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fields) { field in SchemaFieldView(field: field, values: $form) }
            }
            actionRow(acceptTitle: "提交", supported: true) { ["action": "accept", "content": .object(form)] }
        } else {
            Text("此表单包含暂不支持的结构，可以拒绝或取消。").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            actionRow(acceptTitle: "提交", supported: false) { ["action": "accept"] }
        }
    }

    private func actionRow(acceptTitle: String, supported: Bool, accept: @escaping () -> JSON) -> some View {
        footer {
            Button("取消") { submit(["interaction": ["action": "cancel"]]) }.buttonStyle(QuietButtonStyle())
            Button("拒绝") { submit(["interaction": ["action": "decline"]]) }.buttonStyle(WorkbenchButtonStyle())
            Button(acceptTitle) { submit(["interaction": accept()]) }.buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(!supported)
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
                WorkbenchSelect(title: field.label, selection: Binding(get: { values[field.name]?.string ?? "" }, set: { values[field.name] = .string($0) }),
                                options: [WorkbenchOption("", "请选择")] + field.options.map { WorkbenchOption($0.value, $0.label) })
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
                })).textFieldStyle(WorkbenchTextFieldStyle())
            case .text:
                TextField(field.label, text: Binding(get: { values[field.name]?.string ?? field.defaultValue?.string ?? "" }, set: { values[field.name] = .string($0) })).textFieldStyle(WorkbenchTextFieldStyle())
            }
            if let description = field.description { Text(description).font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted) }
        }
    }
}
#endif
