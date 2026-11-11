import AppKit
import SwiftUI

/// An opaque card floating on the frame, as in the reference design.
struct IslandCard: ViewModifier {
    var color: Color = WorkbenchTheme.canvas
    func body(content: Content) -> some View {
        content
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous).strokeBorder(
                    WorkbenchTheme.popupBorder))
    }
}

extension View {
    func islandCard(_ color: Color = WorkbenchTheme.canvas) -> some View { modifier(IslandCard(color: color)) }
}

extension View {
    func workbenchPanel() -> some View {
        self
            .foregroundStyle(WorkbenchTheme.ink)
            .tint(WorkbenchTheme.accent)
            .font(WorkbenchMetrics.ui)
            .buttonStyle(WorkbenchButtonStyle())
            .toggleStyle(WorkbenchToggleStyle())
            .textFieldStyle(WorkbenchTextFieldStyle())
            .scrollContentBackground(.hidden)
            .presentationBackground(WorkbenchTheme.popup)
    }
}
