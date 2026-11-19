#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("workspace.sidebarWidth") private var sidebarWidth: Double = 240

    var body: some View {
        Group {
            if let failure = model.fatalError {
                ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        SidebarView().frame(width: CGFloat(sidebarWidth))
                            .overlay(alignment: .trailing) {
                                SidebarResizeHandle(width: $sidebarWidth)
                            }
                            .transition(.move(edge: .leading).combined(with: .opacity)).zIndex(1)
                        Divider().opacity(0.5)
                    }
                    // Side panes slide; the conversation takes its new width at once, because
                    // re-wrapping every text view on each animation frame is slow and looks wrong.
                    WorkArea().frame(minWidth: 340, maxWidth: .infinity)
                        .transaction { $0.animation = nil }
                    if model.showSessionDetails && model.active != nil {
                        Divider()
                        SessionDetailsView().frame(width: 270)
                            .transition(.move(edge: .trailing).combined(with: .opacity)).zIndex(1)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: sidebarVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.showSessionDetails && model.active != nil)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WorkbenchTheme.border.opacity(0.45)))
                .shadow(color: .black.opacity(0.035), radius: 12, y: 3)
                .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 4)
                .background(WorkbenchTheme.sidebar)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { sidebarVisible.toggle() } label: {
                            Label("切换侧栏", systemImage: "sidebar.left")
                        }.help(sidebarVisible ? "收起侧栏" : "展开侧栏")
                    }


                }
            }
        }
        .task(id: "\(model.currentConfig?.key ?? ""):\(model.isConnected)") {
            let config = model.currentConfig
            let engine = model.engine
            let loader: (() async throws -> JSON)?
            if model.isConnected, let config, let engine {
                loader = { try await engine.machineDetails(config, section: "accountStatus") }
            } else { loader = nil }
            await model.accountStore.observe(source: config?.key ?? "", loader: loader)
        }
        .onAppear { sidebarWidth = min(360, max(200, sidebarWidth)) }
        .tint(WorkbenchTheme.accent)
        .accentColor(WorkbenchTheme.accent)
        .foregroundStyle(WorkbenchTheme.ink)
        // At the top, clear of the composer and its toolbar.
        .overlay(alignment: .top) {
            ZStack {
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(.white).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.14)))
                        .padding(.top, 12).frame(maxWidth: 650).textSelection(.enabled)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.toast)
        }
        .sheet(item: $model.presentation) { AppSheet(destination: $0) }
    }
}
#endif
