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
    @State private var headerHovered = false
    @State private var showAll = false
    @State private var expanded: Bool?
    @State private var renaming: ChatSession?
    @State private var name = ""

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
            ForEach(visibleSessions) { session in
                Button { model.select(session.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if session.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text(historyDisplayTitle(session.name)).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.unreadSessions.contains(session.id) { Circle().fill(WorkbenchTheme.accent).frame(width: 6, height: 6) }
                    }
                    if session.isBusy {
                        Text(statusLabel(session.status)).font(.caption2).foregroundStyle(WorkbenchTheme.accent)
                    }
                }
                }
                .buttonStyle(SidebarNavigationStyle(selected: model.activeId == session.id))
                .accessibilityAddTraits(model.activeId == session.id ? .isSelected : [])
                .help(session.directory + " · " + session.name)
                .contextMenu {
                    Button("重命名…") { name = session.name; renaming = session }
                    Button(session.pinned == true ? "取消固定" : "固定") { model.perform { try model.engine?.setPinned(session.id, session.pinned != true) } }
                    Button(session.archived == true ? "恢复" : "归档") { model.perform { try model.engine?.setArchived(session.id, session.archived != true) } }
                    Button("导出…") { model.exportConversation(session) }
                    Divider()
                    Button("删除…", role: .destructive) { model.deleteConversation(session) }
                }
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
                DisclosureGroup(isExpanded: isExpanded) {
                    rows.padding(.leading, 24)
                    if !searching && (showAll || sessions.count > visibleSessions.count) {
                        Button(showAll ? "收起" : "显示更多（\(sessions.count - visibleSessions.count)）") { showAll.toggle() }
                            .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 6).listRowSeparator(.hidden).selectionDisabled()
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(first.directory == "/" ? "/" : (first.directory as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Button { model.newConversation(in: first) } label: {
                            Image(systemName: "plus").frame(width: 20, height: 20)
                        }.buttonStyle(.plain).help("在此项目中新建对话")
                            .accessibilityLabel("在此项目中新建对话")
                            .disabled(model.projectMissing(first))
                            .opacity(headerHovered ? 1 : 0).allowsHitTesting(headerHovered)
                        Menu { projectActions(first) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("项目操作").accessibilityLabel("项目操作")
                            .opacity(headerHovered ? 1 : 0)
                            .allowsHitTesting(headerHovered)
                    }.contentShape(Rectangle()).onHover { headerHovered = $0 }.help(first.host + " · " + first.directory)
                        .contextMenu { projectActions(first) }
                }
            }
        }
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .onChange(of: model.activeId) {
            if sessions.contains(where: { $0.id == model.activeId }) { expanded = true }
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("对话名称", text: $name)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let session = renaming { model.perform { try model.engine?.rename(session.id, name) } }
                renaming = nil
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).count > 80)
        } message: { Text("输入 1–80 个字符的名称。") }
    }
}
#endif
