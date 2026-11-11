import SwiftUI
import RemoteCCCore

struct SessionMenuAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct WorkspaceTopBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var sidebarVisible: Bool
    /// The machine is named at the top of the sidebar; the title only says which project.
    private var title: String {
        model.active.map { ($0.directory as NSString).lastPathComponent } ?? "claude-mirror"
    }
    var body: some View {
        HStack(spacing: 6) {
            // Leave the standard macOS window controls in their familiar position.
            Color.clear.frame(width: 72, height: 1)
            Button { sidebarVisible.toggle() } label: { WorkbenchIcon(symbol: "sidebar.left").frame(width: 18) }
                .help("切换侧栏").accessibilityLabel("切换侧栏")
            Text(title)
                .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .leading)
                .help(model.active?.directory ?? "")
            Spacer(minLength: 12)
        }
        .buttonStyle(WorkbenchIconButtonStyle(size: 28)).font(WorkbenchMetrics.ui)
        .padding(.horizontal, 10).frame(height: WorkbenchMetrics.header + 6)
        .background(WorkbenchTheme.frame)
    }
}

// Winc popup_menu.rs: 24 pt rows, 9 pt separators, inset highlight and a check column.
struct SessionActionMenu: View {
    @EnvironmentObject private var model: AppModel
    let session: ChatSession
    let close: () -> Void
    @State private var selected: Int?
    @FocusState private var focused: Bool

    private struct Item {
        let title: String
        let icon: String
        var enabled = true
        var checked = false
        let action: () -> Void
    }

    private var items: [Item] {
        [
            Item(title: "同步消息", icon: "arrow.clockwise", enabled: model.isConnected && !session.isBusy && session.remoteOwner == nil && !model.refreshingHistory.contains(session.id)) {
                Task { await model.refreshVisibleHistory(session.id) }
            },
            Item(title: "分支对话", icon: "arrow.triangle.branch") {
                model.perform { if let fork = try model.engine?.fork(session.id) { model.select(fork.id) } }
            },
            Item(title: "导出对话…", icon: "square.and.arrow.up") { model.exportConversation(session) }
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                row(items[index], index: index)
            }
        }
        .padding(.vertical, 5).frame(width: 180)
        .background(WorkbenchTheme.popup, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.popupBorder))
        .shadow(color: WorkbenchTheme.shadow, radius: 12, y: 4)
        .focusable().focusEffectDisabled().focused($focused)
        .task {
            await Task.yield()
            focused = true
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if let selected { activate(items[selected]) }
            return .handled
        }
        .onExitCommand(perform: close)
    }

    private func row(_ item: Item, index: Int) -> some View {
        Button { activate(item) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 9))
                    .opacity(item.checked ? 1 : 0).frame(width: 12)
                WorkbenchIcon(symbol: item.icon)
                Text(item.title).font(WorkbenchMetrics.ui).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 6).frame(height: 24)
            .foregroundStyle(selected == index ? Color.white : WorkbenchTheme.ink)
            .opacity(item.enabled ? 1 : 0.4)
            .background(selected == index ? WorkbenchTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!item.enabled).focusable(false)
        .padding(.horizontal, 4)
        .onHover { over in
            if over && item.enabled { selected = index }
            else if selected == index { selected = nil }
        }
        .accessibilityValue(item.checked ? "已开启" : "")
    }

    private func move(_ step: Int) {
        let enabled = items.indices.filter { items[$0].enabled }
        guard !enabled.isEmpty else { return }
        if let selected, let position = enabled.firstIndex(of: selected) {
            self.selected = enabled[(position + step + enabled.count) % enabled.count]
        } else { selected = step > 0 ? enabled.first : enabled.last }
    }

    private func activate(_ item: Item) {
        guard item.enabled else { return }
        close()
        item.action()
    }
}
