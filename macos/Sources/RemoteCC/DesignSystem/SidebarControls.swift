import AppKit
import SwiftUI

/// A tree row that expands its children, like the reference sidebar: 24 pt, rotating chevron,
/// hover fill; children appear with the tree animation. The label sees the hover state.
struct SidebarDisclosure<Label: View, Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder let label: (Bool) -> Label
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func toggle() { withAnimation(Motion.animation(Motion.tree, reduce: reduceMotion)) { expanded.toggle() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(
                    WorkbenchTheme.inkMuted
                )
                .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                label(hovered)
            }
            .padding(.horizontal, 6).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovered ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityAction { toggle() }
            if expanded {
                content().transition(Motion.disclosure(reduce: reduceMotion))
            }
        }
        .clipped()
    }
}
