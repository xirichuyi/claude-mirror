#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct ProjectGroup: View {
    @EnvironmentObject private var model: AppModel
    let sessions: [ChatSession]
    let searching: Bool
    var flat = false
    var initiallyExpanded = false
    @State private var showAll = false
    @State private var expanded: Bool?

    private var isExpanded: Binding<Bool> {
        Binding(get: { searching || (expanded ?? (initiallyExpanded || sessions.contains { $0.id == model.activeId })) }, set: { expanded = $0 })
    }

    private var visibleSessions: [ChatSession] {
        if flat || searching || showAll { return sessions }
        var result = Array(sessions.prefix(5))
        if let active = sessions.first(where: { $0.id == model.activeId }), !result.contains(where: { $0.id == active.id }) { result.append(active) }
        return result
    }

    private var rows: some View {
        ForEach(visibleSessions) { session in sessionRow(session) }
    }

    private func sessionLabel(_ session: ChatSession) -> some View {
        HStack(spacing: 6) {
            WorkbenchIcon(symbol: session.pinned == true ? "pin" : "bubble.left")
                .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted).frame(width: 16)
            Text(historyDisplayTitle(session.name)).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            // One line per row, as in the reference tree: state is a mark, not a second line.
            if session.isBusy {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 14, height: 14)
            } else if model.unreadSessions.contains(session.id) {
                Circle().fill(WorkbenchTheme.accent).frame(width: 6, height: 6)
            }
        }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let selected = model.activeId == session.id
        let state = session.isBusy ? statusLabel(session.status) : model.unreadSessions.contains(session.id) ? "有新结果" : ""
        return Button { model.select(session.id) } label: { sessionLabel(session) }
            .buttonStyle(SidebarNavigationStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(state)
            .help(session.directory + " · " + session.name + (state.isEmpty ? "" : " · " + state))
            .contextMenu {
                Button("重命名…") {
                    model.presentation = .rename(WorkbenchRename(title: "重命名对话", initial: session.name) { value in
                        model.perform { try model.engine?.rename(session.id, value) }
                    })
                }
                Button(session.pinned == true ? "取消固定" : "固定") { model.perform { try model.engine?.setPinned(session.id, session.pinned != true) } }
                Button(session.archived == true ? "恢复" : "归档") { model.perform { try model.engine?.setArchived(session.id, session.archived != true) } }
                Button("导出…") { model.exportConversation(session) }
                Divider()
                Button("删除…", role: .destructive) { model.deleteConversation(session) }
            }
    }

    @ViewBuilder private func projectActions(_ first: ChatSession) -> some View {
        Text(first.host + " · " + first.directory)
        Button("在项目中新建对话") { model.newConversation(in: first) }.disabled(model.projectMissing(first))
        Button("浏览远端文件夹") {
            model.select(first.id); model.panel = .files; model.showFiles = true
            Task { await model.activeWorkspace?.browse(first.directory) }
        }
        Button("新建隔离工作区…") { model.select(first.id); model.showWorktree = true }
            .disabled(model.projectMissing(first) || !model.isConnected)
        Button("删除远端聊天记录…", role: .destructive) { model.deleteProjectHistory(first) }
            .disabled(!model.isConnected)
        Button("复制文件夹路径") { copyToPasteboard(first.directory) }
        Divider()
        Button(model.showArchived ? "恢复项目" : "从侧栏移除项目…") { model.archiveProject(first, archived: !model.showArchived) }
    }

    var body: some View {
        Group {
            if flat { rows }
            else if let first = sessions.first {
                SidebarDisclosure(expanded: isExpanded) { hovered in
                    HStack(spacing: 6) {
                        WorkbenchIcon(symbol: "folder").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.inkMuted).frame(width: 16)
                        Text(first.directory == "/" ? "/" : (first.directory as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { model.newConversation(in: first) } label: {
                            WorkbenchIcon(symbol: "plus").font(.system(size: 11, weight: .medium)).frame(width: 18, height: 18)
                        }.buttonStyle(.plain).foregroundStyle(WorkbenchTheme.inkMuted).help("在此项目中新建对话")
                            .accessibilityLabel("在此项目中新建对话")
                            .disabled(model.projectMissing(first))
                            .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                        WorkbenchMenu { projectActions(first) } label: { WorkbenchIcon(symbol: "ellipsis").font(.system(size: 11)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("项目操作").accessibilityLabel("项目操作")
                            .opacity(hovered ? 1 : 0)
                            .allowsHitTesting(hovered)
                    }
                    .help(first.host + " · " + first.directory)
                    .contextMenu { projectActions(first) }
                } content: {
                    VStack(alignment: .leading, spacing: 1) {
                        rows
                        if !searching && (showAll || sessions.count > visibleSessions.count) {
                            Button(showAll ? "收起" : "显示更多（\(sessions.count - visibleSessions.count)）") { showAll.toggle() }
                                .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.inkMuted)
                                .padding(.leading, 30).frame(height: 24)
                        }
                    }.padding(.leading, 16)
                }
            }
        }
        .onChange(of: model.activeId) {
            if sessions.contains(where: { $0.id == model.activeId }) { expanded = true }
        }
    }
}
#endif
