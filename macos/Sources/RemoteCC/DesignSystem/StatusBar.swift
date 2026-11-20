import AppKit
import SwiftUI

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
