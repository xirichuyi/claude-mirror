#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct MachineHomeView: View {
    @EnvironmentObject private var model: AppModel
    private var recent: [ChatSession] { Array(model.machineSessions.filter { $0.archived != true && !model.projectMissing($0) }.prefix(6)) }
    private var syncing: Bool { model.currentConfig.map { model.syncingMachines.contains($0.key) } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.currentConfig == nil {
                    GettingStartedView()
                } else if let config = model.currentConfig {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("新对话").font(.system(size: 22, weight: .semibold)).foregroundStyle(WorkbenchTheme.ink)
                        Text(config.displayName).font(.body).foregroundStyle(WorkbenchTheme.inkMuted).lineSpacing(6)
                    }
                    if !model.isConnected {
                        if model.connectionState.status == .error, !model.connectionState.error.isEmpty {
                            ConnectionFailureNotice(config: config, error: model.connectionState.error)
                        } else {
                            HStack(spacing: 12) {
                                Button(syncing ? "正在连接…" : "连接机器") { model.perform { try await model.connect(config) } }
                                    .buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(syncing)
                                if syncing { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    MachineHealthBanner()
                    HStack(spacing: 10) {
                        Button { model.perform { try await model.chooseProject("~") } } label: { Label("在主目录开始对话", systemImage: "house") }
                            .buttonStyle(WorkbenchButtonStyle(prominent: model.isConnected && recent.isEmpty)).disabled(!model.isConnected)
                        Button { model.openProjectPicker() } label: { Label("打开或新建项目", systemImage: "folder.badge.plus") }
                            .buttonStyle(WorkbenchButtonStyle()).disabled(!model.isConnected)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近对话").font(.callout.weight(.medium)).foregroundStyle(WorkbenchTheme.inkMuted)
                            Spacer()
                            if syncing { ProgressView().controlSize(.small) }
                            else {
                                Button { if let config = model.currentConfig { Task { await model.discoverHistory(config) } } } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.plain).disabled(!model.isConnected).help("同步远端历史")
                            }
                        }
                        if recent.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(syncing ? "正在读取远端历史…" : "还没有对话").font(WorkbenchMetrics.ui)
                                Text(model.historyStatus)
                                    .font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkbenchTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
                        } else {
                            VStack(spacing: 4) {
                                ForEach(recent) { session in
                                    Button { model.select(session.id) } label: {
                                        HStack(spacing: 10) {
                                                                                        VStack(alignment: .leading, spacing: 5) {
                                                Text(historyDisplayTitle(session.name)).font(WorkbenchMetrics.ui).lineLimit(1)
                                                Text(session.directory).font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1).truncationMode(.middle)
                                            }
                                            Spacer()
                                            Text(Date(timeIntervalSince1970: session.updatedAt / 1000), format: .dateTime.month().day())
                                                .font(.caption2).foregroundStyle(WorkbenchTheme.inkDim)
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(WorkbenchTheme.inkDim)
                                        }.padding(.vertical, 4).padding(.horizontal, 4).contentShape(Rectangle())
                                    }.buttonStyle(SidebarNavigationStyle())
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 580).padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

}

/// First launch: what the app needs and the three steps to a working conversation.
struct GettingStartedView: View {
    @EnvironmentObject private var model: AppModel
    static let helpURL = URL(string: "https://github.com/xirichuyi/claude-mirror/blob/HEAD/docs/getting-started.md")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("开始使用").font(.system(size: 22, weight: .semibold)).foregroundStyle(WorkbenchTheme.ink)
                Text("镜像 Claude 让你在这台 Mac 上使用服务器里的 Claude Code：代码和 Claude 都在服务器上运行，这里负责对话、审批和查看文件。")
                    .font(.body).foregroundStyle(WorkbenchTheme.inkMuted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "准备一台服务器", "Linux 或 macOS，能用 SSH 登录即可，比如云服务器、公司开发机或家里的电脑。")
                step(2, "添加服务器", "填写地址和密码。连接成功后可以一键设置免密登录。")
                step(3, "自动检查环境", "缺少 Claude Code 或 Node.js 时一键安装；第一次使用需要在服务器上登录 Claude。")
            }
            HStack(spacing: 12) {
                Button { model.showConnect = true } label: { Label("添加服务器", systemImage: "plus") }
                    .buttonStyle(WorkbenchButtonStyle(prominent: true))
                Link("没有服务器？查看入门指南", destination: Self.helpURL).font(.callout)
            }.padding(.top, 4)
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.callout.weight(.semibold)).frame(width: 24, height: 24)
                .background(WorkbenchTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(WorkbenchTheme.border))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
