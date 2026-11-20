import AppKit
import SwiftUI

struct SheetHeading: View {
    let title: String
    var subtitle: String = ""
    let close: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: close) { WorkbenchIcon(symbol: "xmark") }
                .buttonStyle(WorkbenchIconButtonStyle()).help("关闭").accessibilityLabel("关闭")
                .keyboardShortcut(.cancelAction)
                .focusEffectDisabled()
        }
    }
}
