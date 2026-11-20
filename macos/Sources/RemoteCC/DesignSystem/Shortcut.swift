import AppKit
import SwiftUI

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
