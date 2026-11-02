#if canImport(SwiftUI)
import SwiftUI
import AppKit

enum WorkbenchTheme {
    static let canvas = adaptive(light: 0xFAF6F2, dark: 0x242424)
    static let sidebar = adaptive(light: 0xF0EAE3, dark: 0x1C1C1C)
    static let surface = adaptive(light: 0xF6F1EB, dark: 0x2C2C2C)
    static let ink = adaptive(light: 0x272727, dark: 0xEAEAEA)
    static let onInk = adaptive(light: 0xFAFAFA, dark: 0x242424)
    /// Restrained brand accent, with a brighter counterpart for dark appearance.
    static let accent = adaptive(light: 0x353535, dark: 0xDEDEDE)
    static let userBubble = adaptive(light: 0xEDE5DC, dark: 0x343434)
    static let border = ink.opacity(0.14)
    static let sidebarInk = adaptive(light: 0x303030, dark: 0xEAEAEA)
    static let sage = adaptive(light: 0x566746, dark: 0xB4C49E)

    /// One spacing and corner scale for the whole app instead of per-view numbers.
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    static let conversationWidth: CGFloat = 800

    enum Radius { static let small: CGFloat = 6, medium: CGFloat = 10, large: CGFloat = 16 }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}


extension View {
    func workbenchPanel() -> some View {
        self
            .foregroundStyle(WorkbenchTheme.ink)
            .tint(WorkbenchTheme.accent)
            .scrollContentBackground(.hidden)
            .background(WorkbenchTheme.canvas)
            .presentationBackground(WorkbenchTheme.canvas)
    }
}

struct WorkbenchTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorkbenchTheme.border))
    }
}

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
    var body: some View {
        configuration.label
            .foregroundStyle(WorkbenchTheme.sidebarInk)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(WorkbenchTheme.ink.opacity(selected ? 0.09 : hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
    }
}

struct BrandIcon: View {
    var size: CGFloat = 24
    var body: some View {
        if let url = Bundle.main.url(forResource: "BrandIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct ComposerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(enabled ? WorkbenchTheme.onInk : Color.secondary.opacity(0.45))
            .frame(width: 28, height: 28)
            .background(enabled ? WorkbenchTheme.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large))
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
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(prominent ? WorkbenchTheme.onInk : WorkbenchTheme.ink)
            .background(prominent ? WorkbenchTheme.accent : hovered && enabled ? WorkbenchTheme.sidebar : WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small + 2))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small + 2).strokeBorder(prominent ? .clear : WorkbenchTheme.border))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: hovered)
    }
}

/// Quiet actions retain a consistent hit area without a permanent button border.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietButtonBody(configuration: configuration) }
}
private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(7)
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .background(hovered && enabled ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .onHover { hovered = $0 }
    }
}

struct SheetHeading: View {
    let title: String
    var subtitle: String = ""
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.title2.weight(.semibold)).tracking(-0.4)
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark").frame(width: 16, height: 16) }
                .buttonStyle(QuietButtonStyle()).help("关闭").accessibilityLabel("关闭")
                .keyboardShortcut(.cancelAction)
        }
    }
}
#endif
