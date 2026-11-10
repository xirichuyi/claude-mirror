#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Every colour resolves from the active `ThemePalette`, so appearance and palette changes
/// re-colour the whole app without rebuilding views. Token names are this app's roles.
enum WorkbenchTheme {
    private static func token(_ value: @escaping (ThemePalette) -> NSColor) -> Color { Color(nsColor: ThemeStore.dynamic(value)) }

    /// Window background behind the floating cards.
    static let frame = token(\.frame)
    /// Conversation and editor card.
    static let canvas = token(\.card)
    /// Sidebar and inspector cards.
    static let sidebar = token(\.card)
    static let popup = token(\.popup)
    /// Inputs, code blocks and grouped rows.
    static let surface = token(\.surface)
    static let ink = token(\.text)
    static let inkMuted = token(\.textMuted)
    static let inkDim = token(\.textDim)
    static let onInk = Color.white
    static let primaryButton = token(\.accentFill)
    static let accent = token(\.accent)
    static let userBubble = token(\.tint)
    static let border = token(\.border)
    static let popupBorder = token(\.popupBorder)
    static let separator = token(\.separator)
    static let hover = token(\.hover)
    static let selected = token(\.selected)
    static let selection = token(\.selection)
    static let shadow = token(\.shadow)
    static let sidebarInk = token(\.text)
    static let sage = token(\.gitAdded)
    static let error = token(\.error)
    static let warning = token(\.warning)
    static let added = token(\.gitAdded)
    static let removed = token(\.gitRemoved)
    static let modified = token(\.gitModified)

    /// One spacing and corner scale for the whole app instead of per-view numbers.
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    static let conversationWidth: CGFloat = 800

    /// Rows 6, tabs and popups 8, cards 10, pill controls 14.
    enum Radius { static let small: CGFloat = 6, medium: CGFloat = 8, card: CGFloat = 10, large: CGFloat = 14 }
    /// Cards float on the frame: 6 pt from the window edge and from each other.
    enum Island { static let margin: CGFloat = 6, gap: CGFloat = 6 }
}

/// Short, purposeful motion: popups in 150 ms and out 110 ms, dialogs 220/150 ms scaling from
/// 95 %, panels 200 ms, trees 160 ms, hover 120 ms. Reduce Motion turns all of it off.
enum Motion {
    static let popupIn = 0.15, popupOut = 0.11, dialogIn = 0.22, dialogOut = 0.15
    static let panel = 0.2, tree = 0.16, slide = 0.15, hover = 0.12

    static func animation(_ duration: Double, reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: duration) }

    /// Fades in while growing from 95 %, and out while shrinking slightly.
    static var card: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)).animation(.easeOut(duration: dialogIn)),
                    removal: .opacity.combined(with: .scale(scale: 0.98)).animation(.easeIn(duration: dialogOut)))
    }
    static var popup: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(.easeOut(duration: popupIn)),
                    removal: .opacity.animation(.easeIn(duration: popupOut)))
    }
}

/// An opaque card floating on the frame, as in the reference design.
struct IslandCard: ViewModifier {
    var color: Color = WorkbenchTheme.canvas
    func body(content: Content) -> some View {
        content
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous).strokeBorder(WorkbenchTheme.popupBorder))
    }
}

extension View {
    func islandCard(_ color: Color = WorkbenchTheme.canvas) -> some View { modifier(IslandCard(color: color)) }
}


/// Panels are opaque palette cards rather than translucent material: text contrast then holds
/// to the palette's measured ratios regardless of what is behind the window.
struct FrostedBackground: View {
    var material: NSVisualEffectView.Material = .sidebar
    var body: some View {
        (material == .windowBackground ? WorkbenchTheme.popup : WorkbenchTheme.sidebar)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                        .foregroundStyle(selection == option ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                        .background {
                            if selection == option {
                                Capsule().fill(WorkbenchTheme.popup)
                                    .overlay(Capsule().strokeBorder(WorkbenchTheme.popupBorder))
                                    .shadow(color: WorkbenchTheme.shadow.opacity(0.25), radius: 2, y: 1)
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
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small).strokeBorder(WorkbenchTheme.border))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .foregroundStyle(WorkbenchTheme.sidebarInk)
            .padding(.horizontal, 8).padding(.vertical, 3).frame(minHeight: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .background(selected ? WorkbenchTheme.selected : hovered ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
            .animation(Motion.animation(Motion.hover, reduce: reduceMotion), value: hovered)
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
            .background(prominent ? WorkbenchTheme.primaryButton : hovered && enabled ? WorkbenchTheme.hover : WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(prominent ? .clear : WorkbenchTheme.border))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
            .onHover { hovered = $0 }
            .animation(Motion.animation(Motion.hover, reduce: reduceMotion), value: hovered)
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
            .background(hovered && enabled ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .onHover { hovered = $0 }
    }
}

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
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkMuted)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                label(hovered)
            }
            .padding(.horizontal, 6).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityAction { toggle() }
            if expanded {
                content().transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

/// Small dim section titles, as in the reference sidebar.
struct SidebarSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkbenchTheme.inkDim)
            .padding(.leading, 8).padding(.top, 10).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
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
                .focusEffectDisabled()
        }
    }
}
#endif
