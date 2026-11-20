#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct ActivitySheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var stopping = Set<String>()
    @State private var stopErrors: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "任务") { dismiss() }
            Toggle("任务完成或等待确认时通知我", isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) }))
                .font(.caption)
            HStack {
                Button("发送测试通知") { model.testNotification() }.disabled(!model.notificationsEnabled || model.notificationTestRunning)
                if model.notificationsAuthorizing { ProgressView().controlSize(.small) }
                Text(model.notificationTestStatus).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.savedMachines.filter { machine in model.attentionSessions.contains { $0.config.key == machine.key } || model.engine?.connectionState(machine).status != .connected }, id: \.key) { machine in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(machine.displayName, systemImage: "desktopcomputer").font(.headline)
                                Spacer()
                                let online = model.engine?.connectionState(machine).status == .connected
                                Text(online ? "已连接" : "离线 · 状态可能不是最新").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                                if !online { Button("连接") { model.perform { try await model.connect(machine) } } }
                            }
                            let sessions = model.attentionSessions.filter { $0.config.key == machine.key }
                            if sessions.isEmpty { Text("暂无待处理任务").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted) }
                            ForEach(sessions) { session in
                                VStack(alignment: .leading, spacing: 8) {
                                    Button { model.select(session.id); dismiss() } label: {
                                        HStack {
                                            Text(historyDisplayTitle(session.name)).lineLimit(1)
                                            Spacer()
                                            Text(!session.permissions.isEmpty ? "等待确认" : model.unreadSessions.contains(session.id) && !session.isBusy ? "有新结果" : model.activityLabel(session))
                                                .font(.caption).foregroundStyle(WorkbenchTheme.accent)
                                            Image(systemName: "chevron.right").font(.caption)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(SidebarNavigationStyle())
                                    if let error = session.transportError {
                                        Text(error).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                                        Button("重新同步任务") { Task { await model.engine?.attach(session.id) } }
                                            .disabled(model.engine?.connectionState(session.config).status != .connected)
                                    }
                                    ForEach(Array((session.tasks?.array ?? []).enumerated()), id: \.offset) { _, task in
                                        HStack(alignment: .top) {
                                            Image(systemName: task["status"]?.string == "running" ? "circle.dotted" : "checkmark.circle")
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(task["description"]?.string ?? "后台任务").font(.caption).lineLimit(2)
                                                if let summary = task["summary"]?.string { Text(summary).font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(3) }
                                                if let id = task["id"]?.string, let error = stopErrors[session.id + id] { Text(error).font(.caption2).foregroundStyle(WorkbenchTheme.error) }
                                            }
                                            Spacer()
                                            if task["status"]?.string == "running", let id = task["id"]?.string {
                                                let key = session.id + id
                                                Button(stopping.contains(key) ? "正在停止…" : "停止") {
                                                    stopping.insert(key); stopErrors[key] = nil
                                                    Task {
                                                        defer { stopping.remove(key) }
                                                        do { try await model.engine?.stopBackgroundTask(session.id, task: id) }
                                                        catch { stopErrors[key] = error.localizedDescription }
                                                    }
                                                }
                                                .disabled(stopping.contains(key) || model.engine?.connectionState(session.config).status != .connected)
                                            }
                                        }.foregroundStyle(WorkbenchTheme.inkMuted)
                                    }
                                }.padding(12).background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }.padding(16).background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
                    }
                    if model.attentionSessions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle").font(.largeTitle.weight(.light)).foregroundStyle(WorkbenchTheme.accent.opacity(0.7))
                            Text("暂时没有需要处理的任务").font(.body.weight(.medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
            }
        }.padding(24).frame(width: 680, height: 480)
    }
}
#endif
