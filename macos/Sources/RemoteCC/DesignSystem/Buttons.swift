import AppKit
import SwiftUI

struct SidebarNavigationStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarNavigationBody(configuration: configuration, selected: selected)
    }
}

private struct SidebarNavigationBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .foregroundStyle(WorkbenchTheme.sidebarInk)
            .padding(.horizontal, 8).padding(.vertical, 3).frame(minHeight: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .background(
                selected ? WorkbenchTheme.selected : hovered ? WorkbenchTheme.hover : .clear,
                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
            .animation(Motion.animation(Motion.hover, reduce: reduceMotion), value: hovered)
    }
}

struct ComposerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(enabled ? WorkbenchTheme.onInk : WorkbenchTheme.inkDim)
            .frame(width: 28, height: 28)
            .background(
                enabled ? WorkbenchTheme.primaryButton : WorkbenchTheme.hover,
                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WorkbenchButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct WorkbenchButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        configuration.label
            .font(WorkbenchMetrics.ui)
            .padding(.horizontal, 10).frame(minHeight: WorkbenchMetrics.button)
            .foregroundStyle(
                prominent
                    ? WorkbenchTheme.onInk
                    : configuration.role == .destructive ? WorkbenchTheme.error : WorkbenchTheme.ink
            )
            .background(
                prominent
                    ? (configuration.role == .destructive ? WorkbenchTheme.error : WorkbenchTheme.primaryButton)
                    : hovered && enabled ? WorkbenchTheme.hover : WorkbenchTheme.surface,
                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(
                    prominent ? .clear : WorkbenchTheme.border)
            )
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
            .onHover { hovered = $0 }
            .animation(Motion.animation(Motion.hover, reduce: reduceMotion), value: hovered)
    }
}

/// Quiet actions retain a consistent hit area without a permanent button border.
struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = WorkbenchMetrics.button
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, height: height)
    }
}
private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .font(WorkbenchMetrics.ui)
            .padding(.horizontal, 6).frame(minHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .background(
                enabled
                    ? (configuration.isPressed
                        ? WorkbenchTheme.ink.opacity(0.10) : hovered ? WorkbenchTheme.hover : .clear) : .clear,
                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small)
            )
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovered = $0 }
    }
}
