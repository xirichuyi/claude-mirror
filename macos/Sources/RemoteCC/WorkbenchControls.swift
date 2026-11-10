#if canImport(SwiftUI)
import SwiftUI

// Adapted from Winc's theme.rs, view/dialog.rs, view/settings.rs and view/popup_menu.rs.
// Apache-2.0; attribution and the upstream license are bundled in Resources/ThirdParty.
enum WorkbenchMetrics {
    static let row: CGFloat = 24
    static let button: CGFloat = 28
    static let header: CGFloat = 40
    static let status: CGFloat = 26
    static let dialogRadius: CGFloat = 12
    static let ui = Font.system(size: 13)
    static let caption = Font.system(size: 12)
}

struct WorkbenchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? WorkbenchTheme.accent : WorkbenchTheme.surface)
                    RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? WorkbenchTheme.accent : WorkbenchTheme.border)
                    if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                }.frame(width: 14, height: 14)
                configuration.label.foregroundStyle(WorkbenchTheme.ink)
            }.frame(minHeight: WorkbenchMetrics.row).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct WorkbenchMenu<Label: View, Content: View>: View {
    var iconOnly = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var showing = false

    var body: some View {
        Group {
            if iconOnly {
                Button { showing.toggle() } label: { label() }
                    .buttonStyle(WorkbenchIconButtonStyle(selected: showing))
            } else {
                Button { showing.toggle() } label: { label() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2, content: content)
                }
                    .scrollBounceBehavior(.basedOnSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 360)
                    .font(WorkbenchMetrics.ui)
                    .buttonStyle(WorkbenchMenuActionStyle(close: { showing = false }))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(WorkbenchTheme.ink)
                    .padding(5).frame(minWidth: 200)
                    .background(WorkbenchTheme.popup)
                    .presentationBackground(WorkbenchTheme.popup)
                    .onExitCommand { showing = false }
            }
    }
}

private struct WorkbenchMenuActionStyle: PrimitiveButtonStyle {
    let close: () -> Void
    func makeBody(configuration: Configuration) -> some View { WorkbenchMenuAction(configuration: configuration, close: close) }
}

private struct WorkbenchMenuAction: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let close: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        Button {
            close()
            configuration.trigger()
        } label: {
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? WorkbenchTheme.error : WorkbenchTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).frame(minHeight: 28)
                .contentShape(Rectangle())
                .background(hovered && enabled ? WorkbenchTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
    }
}

struct WorkbenchShortcut: View {
    let keys: String
    var body: some View {
        Text(keys).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(WorkbenchTheme.inkDim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorkbenchTheme.border))
    }
}

struct WorkbenchStatusBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8, content: content)
            .font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            .padding(.horizontal, 12).frame(height: WorkbenchMetrics.status)
            .background(WorkbenchTheme.canvas)
            .overlay(alignment: .top) { WorkbenchTheme.separator.frame(height: 1) }
    }
}
#endif

struct WorkbenchOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}

/// Settings and permission forms use the same field outline and compact menu as Winc.
struct WorkbenchSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [WorkbenchOption<Value>]
    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(WorkbenchTheme.inkMuted)
            Spacer(minLength: 8)
            WorkbenchMenu {
                ForEach(options) { option in
                    Button { selection = option.value } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.value == selection { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.value == selection }?.title ?? "选择…").lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(WorkbenchTheme.inkDim)
                }.frame(width: 190).padding(.horizontal, 6)
            }
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorkbenchTheme.border))
            .accessibilityLabel(title)
        }.font(WorkbenchMetrics.ui).frame(minHeight: 32)
    }
}
