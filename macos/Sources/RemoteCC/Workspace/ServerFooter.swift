import AppKit
import SwiftUI

/// Sidebar footer: places you visit occasionally — archive, every machine's tasks, settings.
struct ServerFooter: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.showArchived.toggle()
            } label: {
                Label(model.showArchived ? "全部对话" : "归档", systemImage: "archivebox")
            }.buttonStyle(SidebarNavigationStyle(selected: model.showArchived))
            Button {
                model.showActivity = true
            } label: {
                WorkbenchIcon(symbol: "bell")
                    .overlay(alignment: .topTrailing) {
                        if !model.attentionSessions.isEmpty {
                            Circle().fill(WorkbenchTheme.accent).frame(width: 5, height: 5).offset(x: 3, y: -2)
                        }
                    }
            }.buttonStyle(WorkbenchIconButtonStyle()).help("所有机器的任务").accessibilityLabel("所有机器的任务")
            Button {
                model.showSettings = true
            } label: {
                WorkbenchIcon(symbol: "gearshape")
            }
            .buttonStyle(WorkbenchIconButtonStyle()).help("设置（⌘,）").accessibilityLabel("设置")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1).padding(.horizontal, 10)
        }
    }
}
