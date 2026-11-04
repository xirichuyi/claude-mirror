#if canImport(SwiftUI)
import SwiftUI
import AppKit

enum WorkbenchTheme {
    // Neutral surfaces and graphite controls; never inherit a blue system accent.
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let ink = Color.primary
    static let onInk = Color.white
    static let primaryButton = Color.black
    static let accent = Color(nsColor: .labelColor)
    static let userBubble = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let border = Color(nsColor: .separatorColor)
    static let sidebarInk = Color.primary
    static let sage = Color.green

    /// One spacing and corner scale for the whole app instead of per-view numbers.
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    static let conversationWidth: CGFloat = 800

    enum Radius { static let small: CGFloat = 6, medium: CGFloat = 10, large: CGFloat = 16 }


}


/// AppKit's traditional blur samples the backdrop, without an opaque tint overlay.
struct FrostedBackground: View {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceTransparency {
            WorkbenchTheme.sidebar
        } else {
            ClassicVisualEffect(material: material, blendingMode: blendingMode)
                .saturation(0)
                .overlay(colorScheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.68))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ClassicVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        updateNSView(view, context: context)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        // A background must accept its parent's size, never feed intrinsic sizing into split views.
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != blendingMode { view.blendingMode = blendingMode }
        if view.state != .active { view.state = .active }
        if view.isEmphasized { view.isEmphasized = false }
    }
}


extension View {
    func workbenchPanel() -> some View {
        self
            .foregroundStyle(WorkbenchTheme.ink)
            .tint(WorkbenchTheme.accent)
            .scrollContentBackground(.hidden)
            .presentationBackground { FrostedBackground(material: .windowBackground) }
    }
}


/// Horizontal segmented choices; sidebar navigation keeps its separate gray selection.
struct CapsulePicker<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.callout.weight(selection == option ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(selection == option ? Color.white : Color.secondary)
                        .background {
                            if selection == option {
                                Capsule().fill(Color(white: 0.17))
                                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(WorkbenchTheme.surface.opacity(0.7), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
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
            .background(Color.primary.opacity(selected ? 0.065 : hovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 6))
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
            .background(enabled ? WorkbenchTheme.primaryButton : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.large))
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
            .background(prominent ? WorkbenchTheme.primaryButton : hovered && enabled ? WorkbenchTheme.sidebar : WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(prominent ? .clear : WorkbenchTheme.border))
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
