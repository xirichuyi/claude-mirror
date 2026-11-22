#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct SessionDetailsView: View {
    @EnvironmentObject private var model: AppModel
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
                        Label("上下文", systemImage: "gauge.with.dots.needle.33percent").font(.subheadline.weight(.semibold))
                        if let context = session.context {
                            ProgressView(value: context.fraction)
                            Text("\(Int(context.usedTokens)) / \(Int(context.maxTokens)) tokens · \(Int((context.fraction * 100).rounded()))%")
                                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        } else {
                            Text("回复完成后显示上下文用量").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        }
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
        }.background(WorkbenchTheme.sidebar)
    }
}
#endif
