import SwiftUI
import RemoteCCCore

struct WorkspaceSidebarTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Labelled segments: four bare icons read as decoration, not as the sidebar's views.
        HStack(spacing: 2) {
            tab("对话", selected: !model.showFiles) {
                model.showFiles = false
                model.focusChat()
            }
            ForEach(SidePanel.allCases) { panel in
                tab(panel.rawValue, selected: model.showFiles && model.panel == panel) { model.openPanel(panel) }
            }
        }
        .padding(2)
        .background(WorkbenchTheme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { if !selected { action() } } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(selected ? WorkbenchTheme.canvas : .clear, in: RoundedRectangle(cornerRadius: 5))
                .shadow(color: selected ? WorkbenchTheme.shadow.opacity(0.5) : .clear, radius: 1, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkspaceStatusBar: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(model.isConnected ? WorkbenchTheme.sage : WorkbenchTheme.inkMuted.opacity(0.5)).frame(width: 6, height: 6)
                Text(model.currentConfig.map { (model.isConnected ? "已连接 " : "未连接 ") + $0.displayName } ?? "未添加服务器")
            }
            if let session = model.active {
                Text(session.directory).lineLimit(1).truncationMode(.middle)
            }
            if let branch = model.activeWorkspace?.gitStatus?.branch {
                Label(branch.components(separatedBy: "...").first ?? branch, systemImage: "arrow.triangle.branch").lineLimit(1).help(branch)
            }
            Spacer(minLength: 8)
            if let session = model.active {
                Button { model.showActivity = true } label: { Text(model.activityLabel(session)) }
                    .buttonStyle(QuietButtonStyle()).help("查看任务状态")
            }
            AccountQuotaView(store: model.accountStore)
        }
        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted)
        .padding(.horizontal, 14).frame(height: 26)
        .background(WorkbenchTheme.frame)
    }
}

