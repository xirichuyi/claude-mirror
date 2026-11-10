#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct AccountStatusSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AccountStore
    private var status: JSON? { store.status }
    @State private var environment: JSON?
    @State private var loading = false
    @State private var failure: String?
    @State private var revision = 0

    private var source: String { (model.currentConfig?.key ?? "") + ":\(model.isConnected):\(revision)" }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "账号与 Claude Code") { dismiss() }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.currentConfig?.displayName ?? "未选择机器").font(.headline)
                    if loading { ProgressView("正在读取远端信息…") }
                    if !model.isConnected { Text("连接机器后查看账号与环境。").foregroundStyle(WorkbenchTheme.inkMuted) }
                    if let failure { Text(failure).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled) }
                    if let status { accountSection(status) }
                    if let session = model.active { sessionSection(session) }
                    if let environment { environmentSection(environment) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 24)
            }
            HStack {
                Text("信息来自远端 Claude Code；未返回的字段显示为“未报告”。")
                    .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                Spacer()
                Button("刷新") { revision += 1 }.disabled(loading || !model.isConnected)
            }.padding(20)
        }
        .frame(width: 640, height: 640)
        .task(id: source) { await load() }
    }

    private func accountSection(_ value: JSON) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登录账号").font(.headline)
            if let error = value["accountError"]?.string { Text(error).foregroundStyle(WorkbenchTheme.inkMuted) }
            let account = value["account"]
            row("邮箱", account?["email"]?.string)
            row("组织", account?["organization"]?.string)
            row("订阅", account?["subscriptionType"]?.string)
            row("服务提供方", displayValue(account?["apiProvider"]?.string))
            row("登录凭据来源", account?["tokenSource"]?.string)
            row("API Key 来源", account?["apiKeySource"]?.string)
            Divider()
            row("Claude Code 版本", value["version"]?.string)
            row("默认输出样式", displayValue(value["outputStyle"]?.string))
            row("快速模式", displayValue(value["fastMode"]?.string))
            if let reason = value["fastModeDisabledReason"]?.string { row("快速模式不可用原因", displayValue(reason)) }
            ForEach(value["quota"]?["windows"]?.array ?? [], id: \.self) { window in
                if let used = window["used"]?.double {
                    row(window["id"]?.string == "five_hour" ? "五小时已用" : "本周已用", String(format: "%.0f%%", used))
                    if let reset = window["resetsAt"]?.string { row("重置时间", resetTime(reset)) }
                }
            }
            if let error = value["quotaError"]?.string { Text("额度：" + error).foregroundStyle(WorkbenchTheme.inkMuted) }
            Text("检测到任一周期已用达到 95% 时停止。同一远端登录已用达到 90% 后限制并行任务；用量反馈有延迟，无法保证精确保留 5%。").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
        }
    }

    private func sessionSection(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("当前对话").font(.headline)
            row("项目", session.directory)
            row("模型", session.model ?? session.preferences?.selectedModel)
            row("状态", statusLabel(session.status))
            row("会话 ID", session.remoteSessionId)
            HStack {
                Button("模型与权限") { dismiss(); model.showPreferences = true }
                Button("上下文与用量") { dismiss(); model.showUsage = true }
                Button("连接器与插件") { dismiss(); model.openTools("mcp") }
            }.buttonStyle(WorkbenchButtonStyle())
        }
    }

    private func environmentSection(_ value: JSON) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("机器默认环境").font(.headline)
            Text("从远端主目录读取。项目专属技能、MCP、插件与任务请在当前对话的会话工具中查看。")
                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            if let error = value["capabilitiesError"]?.string { Text(error).foregroundStyle(WorkbenchTheme.inkMuted) }
            let capabilities = value["capabilities"]
            entries("可用模型", capabilities?["models"]?.array ?? [], name: "displayName", fallback: "value")
            entries("命令与技能", capabilities?["commands"]?.array ?? [], name: "name", fallback: "name")
            entries("Agents", capabilities?["agents"]?.array ?? [], name: "name", fallback: "name")
            if let styles = capabilities?["outputStyles"]?.array { row("可用输出样式", styles.compactMap(\.string).joined(separator: "、")) }
            if let error = value["mcpError"]?.string { Text("MCP：" + error).foregroundStyle(WorkbenchTheme.inkMuted) }
            DisclosureGroup("MCP 服务器（\(value["mcp"]?.array?.count ?? 0)）") {
                ForEach(value["mcp"]?.array ?? [], id: \.self) { server in
                    VStack(alignment: .leading, spacing: 6) {
                        row(server["name"]?.string ?? "MCP", server["status"]?.string)
                        if let error = server["error"]?.string { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
                        entries("工具", server["tools"]?.array ?? [], name: "name", fallback: "name")
                    }.padding(.vertical, 6)
                }
            }
        }
    }

    private func entries(_ title: String, _ items: [JSON], name: String, fallback: String) -> some View {
        DisclosureGroup("\(title)（\(items.count)）") {
            ForEach(items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item[name]?.string ?? item[fallback]?.string ?? "未报告名称").font(.subheadline.weight(.medium))
                    if let description = item["description"]?.string { Text(description).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).textSelection(.enabled)
            }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(WorkbenchTheme.inkMuted).frame(width: 130, alignment: .leading)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "未报告").textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(.callout)
    }

    private func displayValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return ["firstParty": "Anthropic", "bedrock": "Amazon Bedrock", "vertex": "Google Vertex AI",
                "foundry": "Microsoft Foundry", "gateway": "企业网关", "default": "默认",
                "off": "关闭", "on": "开启", "cooldown": "冷却中",
                "sdk_opt_in_required": "当前客户端未启用快速模式", "extra_usage_disabled": "未启用额外用量",
                "network_error": "网络错误", "not_first_party": "当前服务提供方不支持",
                "model_not_allowed": "当前模型不支持", "disabled_by_env": "远端环境已禁用",
                "preference": "已在偏好设置中关闭", "pending": "正在确认", "unknown": "原因未报告"][raw] ?? raw
    }

    private func resetTime(_ raw: String) -> String {
        guard let date = QuotaReset.date(raw) else { return raw }
        return QuotaReset.localTime(date)
    }

    @MainActor private func load() async {
        environment = nil; failure = nil
        guard model.isConnected, let config = model.currentConfig, let engine = model.engine else { return }
        loading = true
        defer { loading = false }
        do {
            await store.refresh()
            try Task.checkCancellation()
            let details = try await engine.machineDetails(config, section: "environmentStatus")
            try Task.checkCancellation()
            environment = details
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}
#endif
