#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RemoteCCCore

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
                if sending { ProgressView().controlSize(.mini); Text("正在提交…").foregroundStyle(WorkbenchTheme.inkMuted) }
            }.font(.subheadline.weight(.medium)).padding(.bottom, 4)
            if permission.kind == "elicitation" { elicitation } else { approval }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error) }
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
        if let description = permission.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if question { questions }
                else {
                    if let file = view.file { Button(file) { model.open(file) }.buttonStyle(.link) }
                    if let subject = view.subject, permission.name != "Bash" { Text(subject).foregroundStyle(WorkbenchTheme.inkMuted) }
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
        TextField(permission.name == "ExitPlanMode" ? "对计划的修改意见" : "拒绝时给 Claude 的说明（可选）", text: $reason).textFieldStyle(WorkbenchTextFieldStyle()).font(.caption)
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
                    TextField("输入你的回答，也可选择下方建议", text: Binding(get: { answers[question] ?? "" }, set: { answers[question] = $0 })).textFieldStyle(WorkbenchTextFieldStyle())
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
        if let server = request?["serverName"]?.string { Text(server).font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted) }
        if let message = request?["message"]?.string { Text(message).textSelection(.enabled) }
        if request?["mode"]?.string == "url", let link = request?["url"]?.string, let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") {
            Text(link).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled)
            // Opening is the user's click; it is not treated as proof that authorization succeeded.
            Button("打开 " + (url.host ?? link)) { NSWorkspace.shared.open(url) }
            actionRow(acceptTitle: "已完成，继续", supported: true) { ["action": "accept"] }
        } else if let fields = try? SchemaField.fields(request?["requestedSchema"]) {
            ForEach(fields) { field in SchemaFieldView(field: field, values: $form) }
            actionRow(acceptTitle: "提交", supported: true) { ["action": "accept", "content": .object(form)] }
        } else {
            Text("此表单包含暂不支持的结构，可以拒绝或取消。").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
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
                        .tint(selected.contains(option.0) ? WorkbenchTheme.accent : WorkbenchTheme.inkMuted)
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
                })).textFieldStyle(WorkbenchTextFieldStyle())
            case .text:
                TextField(field.label, text: Binding(get: { values[field.name]?.string ?? field.defaultValue?.string ?? "" }, set: { values[field.name] = .string($0) })).textFieldStyle(WorkbenchTextFieldStyle())
            }
            if let description = field.description { Text(description).font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted) }
        }
    }
}
#endif
