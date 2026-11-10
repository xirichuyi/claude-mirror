import SwiftUI
import RemoteCCCore

struct WorkspaceSidebarTabs: View {
    @EnvironmentObject private var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selection: Int { model.showFiles ? (model.panel == .files ? 1 : model.panel == .changes ? 2 : 3) : 0 }

    var body: some View {
        HStack(spacing: 2) {
            tab("对话", symbol: "bubble.left.and.bubble.right", selected: !model.showFiles) {
                model.showFiles = false
                model.focusChat()
            }
            ForEach(SidePanel.allCases) { panel in
                tab(panel.rawValue, symbol: panel == .files ? "doc.on.doc" : panel == .search ? "magnifyingglass" : "arrow.triangle.branch",
                    selected: model.showFiles && model.panel == panel) { model.openPanel(panel) }
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(WorkbenchTheme.selected).frame(width: 28, height: 28)
                .offset(x: CGFloat(selection) * 30)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selection)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 8).frame(height: 36)
    }

    private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { if !selected { action() } } label: {
            WorkbenchIcon(symbol: symbol)
        }
        .buttonStyle(WorkbenchIconButtonStyle(size: 28)).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkspaceStatusBar: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            MachineSwitcher(compact: true)
            Label(model.currentConfig?.displayName ?? "未连接主机", systemImage: model.isConnected ? "network" : "network.slash")
                .foregroundStyle(model.isConnected ? WorkbenchTheme.accent : WorkbenchTheme.inkMuted)
            if let session = model.active {
                Text(session.directory).lineLimit(1).truncationMode(.middle)
            }
            if let branch = model.activeWorkspace?.gitStatus?.branch {
                Label(branch.components(separatedBy: "...").first ?? branch, systemImage: "arrow.triangle.branch").lineLimit(1).help(branch)
            }
            Spacer(minLength: 8)
            Text(model.active.map { statusLabel($0.status) } ?? (model.isConnected ? "SSH 已连接" : "离线"))
            AccountQuotaView(store: model.accountStore)
            Button { model.showSettings = true } label: { WorkbenchIcon(symbol: "gearshape") }
                .buttonStyle(WorkbenchIconButtonStyle()).help("设置").accessibilityLabel("设置")
        }
        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted)
        .padding(.horizontal, 14).frame(height: 26)
        .background(WorkbenchTheme.frame)
    }
}

