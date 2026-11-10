#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarVisible = true
    @AppStorage("workspace.sidebarWidth") private var sidebarWidth: Double = 240
    @AppStorage(ThemeStore.modeKey) private var themeMode = ThemeStore.Mode.system.rawValue
    @AppStorage(ThemeStore.darkKey) private var darkTheme = ThemePalette.midnight.id
    @AppStorage(ThemeStore.lightKey) private var lightTheme = ThemePalette.daylight.id
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let failure = model.fatalError {
                ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                // Separate cards floating on the window frame, as in the reference design.
                HStack(spacing: WorkbenchTheme.Island.gap) {
                    if sidebarVisible {
                        SidebarView().frame(width: CGFloat(sidebarWidth))
                            .islandCard(WorkbenchTheme.sidebar)
                            .overlay(alignment: .trailing) {
                                SidebarResizeHandle(width: $sidebarWidth).offset(x: WorkbenchTheme.Island.gap / 2)
                            }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    WorkArea().frame(minWidth: 340, maxWidth: .infinity)
                        .islandCard()
                    if model.showSessionDetails && model.active != nil {
                        SessionDetailsView().frame(width: 270)
                            .islandCard(WorkbenchTheme.sidebar)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(Motion.animation(Motion.panel, reduce: reduceMotion), value: sidebarVisible)
                .animation(Motion.animation(Motion.panel, reduce: reduceMotion), value: model.showSessionDetails)
                .padding(.horizontal, WorkbenchTheme.Island.margin).padding(.bottom, WorkbenchTheme.Island.margin)
                .background(WorkbenchTheme.frame)
                .toolbarBackground(WorkbenchTheme.frame, for: .windowToolbar)
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
        .onAppear { sidebarWidth = min(360, max(200, sidebarWidth)); ThemeStore.apply() }
        .onChange(of: themeMode) { ThemeStore.apply() }
        // Palette changes keep the appearance, so force one redraw with the new colours.
        .id(darkTheme + ":" + lightTheme)
        .tint(WorkbenchTheme.accent)
        .accentColor(WorkbenchTheme.accent)
        .foregroundStyle(WorkbenchTheme.ink)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(WorkbenchTheme.ink)
                    .background(WorkbenchTheme.popup, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
                    .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(WorkbenchTheme.popupBorder))
                    .shadow(color: WorkbenchTheme.shadow, radius: 16, y: 6)
                    .padding(.bottom, 24).frame(maxWidth: 650).textSelection(.enabled)
                    .transition(Motion.card)
            }
        }
        .animation(Motion.animation(Motion.dialogIn, reduce: reduceMotion), value: model.toast)
        .sheet(item: $model.presentation) { AppSheet(destination: $0) }
    }
}
#endif
