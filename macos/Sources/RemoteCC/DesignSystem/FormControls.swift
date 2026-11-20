import AppKit
import SwiftUI

struct WorkbenchTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        WorkbenchField(configuration: configuration)
    }
}

private struct WorkbenchField<Label: View>: View {
    let configuration: TextField<Label>
    @FocusState private var focused: Bool
    var body: some View {
        configuration.textFieldStyle(.plain).focused($focused)
            .modifier(WorkbenchFieldSurface(focused: focused))
    }
}

struct WorkbenchOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// Settings and permission forms use the same field outline and compact menu as Winc.
struct WorkbenchSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [WorkbenchOption<Value>]
    var body: some View {
        WorkbenchFormRow(title) {
            WorkbenchMenu {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.value == selection {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.value == selection }?.title ?? "选择…").lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(
                        WorkbenchTheme.inkDim)
                }.frame(maxWidth: .infinity).padding(.horizontal, 6)
            }
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorkbenchTheme.border))
            .accessibilityLabel(title)
        }.font(WorkbenchMetrics.ui).frame(minHeight: WorkbenchMetrics.button)
    }
}

/// Shared form geometry keeps text fields, secure fields and selectors on one grid.
struct WorkbenchFormRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchMetrics.formGap) {
            Text(title).font(WorkbenchMetrics.ui).foregroundStyle(WorkbenchTheme.inkMuted)
                .frame(width: WorkbenchMetrics.formLabel, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: WorkbenchMetrics.button)
    }
}

struct WorkbenchFieldSurface: ViewModifier {
    var focused = false
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.font(WorkbenchMetrics.ui).padding(.horizontal, 8)
            .frame(minHeight: WorkbenchMetrics.button)
            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small)
                    .strokeBorder(focused ? WorkbenchTheme.accent : WorkbenchTheme.border)
            )
            .opacity(enabled ? 1 : 0.45)
    }
}
