import AppKit
import SwiftUI

struct WorkbenchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? WorkbenchTheme.accent : WorkbenchTheme.surface)
                    RoundedRectangle(cornerRadius: 4).strokeBorder(
                        configuration.isOn ? WorkbenchTheme.accent : WorkbenchTheme.border)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }.frame(width: 14, height: 14)
                configuration.label.foregroundStyle(WorkbenchTheme.ink)
            }.frame(minHeight: WorkbenchMetrics.row).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
