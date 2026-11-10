#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct SessionDetailsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var context: JSON?
    @State private var contextError: String?
    @State private var loading = false
    @State private var revision = 0

    private var source: String {
        "\(model.activeId ?? ""): \(model.active?.status ?? ""): \(model.isConnected):\(revision)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("会话详情").font(.headline)
                    Spacer()
                    Button { model.showSessionDetails = false } label: { WorkbenchIcon(symbol: "xmark") }
                        .buttonStyle(QuietButtonStyle()).help("收起会话详情").accessibilityLabel("收起会话详情")
                }
                if let session = model.active {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("环境", systemImage: "server.rack").font(.subheadline.weight(.semibold))
                        Text(session.config.displayName).font(.callout)
                        Text(session.directory).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled)
                        Label(model.isConnected ? statusLabel(session.status) : "未连接", systemImage: model.isConnected ? "circle.fill" : "network.slash")
                            .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        Button("切换项目") { model.openProjectPicker() }.disabled(!model.isConnected)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("上下文", systemImage: "gauge.with.dots.needle.33percent").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button { revision += 1 } label: { WorkbenchIcon(symbol: "arrow.clockwise") }
                                .buttonStyle(QuietButtonStyle()).disabled(loading || !model.isConnected).help("刷新上下文").accessibilityLabel("刷新上下文")
                        }
                        if loading { ProgressView().controlSize(.small) }
                        if let context, let total = context["totalTokens"]?.double, let limit = context["maxTokens"]?.double, limit > 0 {
                            ProgressView(value: min(total, limit), total: limit)
                            Text("\(Int(total)) / \(Int(limit)) tokens · \(Int(total / limit * 100))%")
                                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        } else {
                            Text(contextError ?? "开始对话后显示实时上下文").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        }
                        Button("查看用量明细") { model.showUsage = true }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("后台任务", systemImage: "checklist").font(.subheadline.weight(.semibold))
                        let tasks = session.tasks?.array ?? []
                        Text(tasks.isEmpty ? "暂无后台任务" : "\(tasks.filter { $0["status"]?.string == "running" }.count) 个正在运行 · 共 \(tasks.count) 个")
                            .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        ForEach(Array(tasks.prefix(3)), id: \.self) { task in
                            Text(task["description"]?.string ?? task["summary"]?.string ?? task["id"]?.string ?? "任务")
                                .font(.caption).lineLimit(2)
                        }
                        Button("查看与管理任务") { model.openTools("tasks") }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("项目配置", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                        Button("技能与命令") { model.openTools("skills") }
                        Button("连接器 · MCP") { model.openTools("mcp") }
                        Button("插件") { model.openTools("plugins") }
                        Button("记忆与配置") { model.openTools("config") }
                    }
                }
            }.buttonStyle(.link).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.background { FrostedBackground() }
        .task(id: source) {
            context = nil; contextError = nil
            guard let session = model.active, session.remoteOwner != nil, model.isConnected, let engine = model.engine else { return }
            loading = true
            defer { loading = false }
            do {
                let result = try await engine.details(session.id, section: "context")
                try Task.checkCancellation()
                context = result
            } catch is CancellationError { }
            catch { contextError = error.localizedDescription }
        }
    }
}
#endif
