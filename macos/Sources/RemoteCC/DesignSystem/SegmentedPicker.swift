import AppKit
import SwiftUI

/// Horizontal segmented choices; sidebar navigation keeps its separate gray selection.
struct CapsulePicker<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.callout.weight(selection == option ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(selection == option ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).fill(WorkbenchTheme.popup)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(
                                            WorkbenchTheme.popupBorder)
                                    )
                                    .shadow(color: WorkbenchTheme.shadow.opacity(0.25), radius: 2, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            WorkbenchTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
