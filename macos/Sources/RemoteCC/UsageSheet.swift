#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct UsageSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var context: JSON?
    @State private var error = ""
    @State private var loading = false
    @State private var revision = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "对话用量与上下文") { dismiss() }
            Text(model.active?.model ?? "远端默认模型").foregroundStyle(.secondary)
            if let usage = model.active?.usage {
                HStack(spacing: 10) {
                    metric("最近一轮输入", value: usage["lastTurn"]?["input_tokens"]?.int.map(String.init) ?? "—")
                    metric("最近一轮输出", value: usage["lastTurn"]?["output_tokens"]?.int.map(String.init) ?? "—")
                    metric("远端报告费用", value: usage["totalCostUSD"]?.double.map { String(format: "$%.4f", $0) } ?? "—")
                }
                Text("费用为 SDK 报告值，不等同于订阅账单。").font(.caption).foregroundStyle(.secondary)
            }
            Button("查看订阅用量") { model.presentation = .accountUsage }
                .buttonStyle(WorkbenchButtonStyle())
            Divider()
            if loading { ProgressView("读取实时上下文…") }
            if let context {
                let total = context["totalTokens"]?.double ?? 0
                let maximum = context["maxTokens"]?.double ?? 1
                ProgressView(value: min(total, maximum), total: max(1, maximum))
                Text("\(Int(total)) / \(Int(maximum)) tokens").font(.caption).foregroundStyle(.secondary)
                ForEach(Array((context["categories"]?.array ?? []).enumerated()), id: \.offset) { _, item in
                    HStack { Text(item["name"]?.string ?? "其他"); Spacer(); Text("\(item["tokens"]?.int ?? 0)").monospacedDigit() }.font(.caption)
                }
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.secondary) }
            Button("刷新") { revision += 1 }.disabled(loading || !model.isConnected)
        }.padding(24).frame(width: 520).task(id: "\(model.activeId ?? ""):\(model.isConnected):\(revision)") { await load() }
    }
    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(WorkbenchTheme.border))
    }
    private func load() async {
        context = nil; error = ""
        guard model.isConnected else { error = "连接服务器后可读取实时上下文。"; return }
        guard let session = model.active, let engine = model.engine else { return }
        guard session.remoteOwner != nil else { error = "这是一条历史对话；继续对话后可查看实时上下文。"; return }
        loading = true
        defer { loading = false }
        do {
            let result = try await engine.details(session.id, section: "context")
            try Task.checkCancellation()
            context = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
#endif
