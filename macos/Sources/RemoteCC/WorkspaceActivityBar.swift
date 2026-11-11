import SwiftUI
import RemoteCCCore

struct WorkspaceSidebarTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Winc-style compact segments keep the navigation separate from pane actions.
        HStack(spacing: 2) {
            tab("对话", icon: "bubble.left", selected: !model.showFiles) {
                model.showFiles = false
                model.focusChat()
            }
            ForEach(SidePanel.allCases) { panel in
                tab(panel.rawValue, icon: panel == .files ? "doc.on.doc" : panel == .changes ? "arrow.triangle.branch" : "magnifyingglass", selected: model.showFiles && model.panel == panel) { model.openPanel(panel) }
            }
        }
        .padding(2)
        .background(WorkbenchTheme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).frame(height: 36)
    }

    private func tab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { if !selected { action() } } label: {
            WorkbenchIcon(symbol: icon).frame(width: 16, height: 16)
                .foregroundStyle(selected ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                .frame(width: 30, height: 26)
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
                Text(model.currentConfig == nil ? "未添加服务器" : model.isConnected ? "已连接" : "未连接")
            }.help(model.currentConfig.map { $0.displayName + " · " + $0.host } ?? "")
            if let session = model.active {
                Text(session.directory).lineLimit(1).truncationMode(.middle)
            }
            if let branch = model.activeWorkspace?.gitStatus?.branch {
                Label(branch.components(separatedBy: "...").first ?? branch, systemImage: "arrow.triangle.branch").lineLimit(1).help(branch)
            }
            Spacer(minLength: 8)
            if let session = model.active {
                Button { model.showActivity = true } label: { Text(model.activityLabel(session)).lineLimit(1).frame(width: 88, alignment: .trailing) }
                    .buttonStyle(QuietButtonStyle()).help("查看任务状态")
            }
            AccountQuotaView(store: model.accountStore)
        }
        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.inkMuted)
        .padding(.horizontal, 14).frame(height: 26)
        .background(WorkbenchTheme.frame)
    }
}

