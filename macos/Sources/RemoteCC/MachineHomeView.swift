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
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.currentConfig == nil ? "连接服务器" : "新对话")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(WorkbenchTheme.ink)
                    Text(model.currentConfig == nil ? "使用服务器上的 Claude Code。" : model.currentConfig!.displayName)
                        .font(.body).foregroundStyle(WorkbenchTheme.inkMuted).lineSpacing(6)
                    if model.currentConfig == nil || !model.isConnected {
                    HStack(spacing: 12) {
                        if let config = model.currentConfig {
                            if !model.isConnected {
                                Button("连接机器") { model.perform { try await model.connect(config) } }
                                    .buttonStyle(WorkbenchButtonStyle()).disabled(syncing)
                            }
                        } else {
                            Button { model.showConnect = true } label: { Label("添加服务器", systemImage: "plus") }
                                .buttonStyle(WorkbenchButtonStyle(prominent: true))
                            Text("支持 SSH 别名与 user@host").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkDim)
                        }
                    }.padding(.top, 4)
                    }
                }
                if model.currentConfig != nil {
                    Button { model.openProjectPicker() } label: { Label("打开或新建项目", systemImage: "folder.badge.plus") }
                        .buttonStyle(WorkbenchButtonStyle()).disabled(!model.isConnected)
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
#endif
