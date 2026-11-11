#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("workspace.sidebarWidth") private var savedSidebarWidth: Double = 240
    @State private var sidebarWidth: Double = 240
    @AppStorage(ThemeStore.modeKey) private var themeMode = ThemeStore.Mode.system.rawValue
    @AppStorage(ThemeStore.darkKey) private var darkTheme = ThemePalette.midnight.id
    @AppStorage(ThemeStore.lightKey) private var lightTheme = ThemePalette.daylight.id
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let failure = model.fatalError {
                ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                VStack(spacing: 0) {
                WorkspaceTopBar(sidebarVisible: $model.sidebarVisible)
                HStack(spacing: WorkbenchTheme.Island.gap) {
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            MachineSwitcher().frame(maxWidth: .infinity, alignment: .leading)
                            WorkspaceSidebarTabs().fixedSize()
                        }.padding(.horizontal, 8).frame(height: 44)
                        RetainedPaneLayout(selection: model.showFiles ? 1 : 0, parkInactive: false) {
                            SidebarView().sidebarPaneVisible(!model.showFiles && model.sidebarVisible)
                            FilePanel().sidebarPaneVisible(model.showFiles && model.sidebarVisible)
                        }.clipped()
                        ServerFooter()
                    }
                    .frame(width: CGFloat(sidebarWidth))
                    .islandCard(WorkbenchTheme.sidebar)
                    .frame(width: model.sidebarVisible ? CGFloat(sidebarWidth) : 0, alignment: .leading)
                    .clipped()
                    .paneVisible(model.sidebarVisible)
                    .overlay(alignment: .trailing) {
                        if model.sidebarVisible {
                            SidebarResizeHandle(width: $sidebarWidth, onCommit: { savedSidebarWidth = sidebarWidth })
                                .offset(x: WorkbenchTheme.Island.gap / 2)
                        }
                    }
                    // WorkArea draws its own cards: chat, editor and files are separate islands.
                    WorkArea().frame(minWidth: 340, maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            if model.showSessionDetails && model.active != nil {
                                SessionDetailsView().frame(width: 270)
                                    .islandCard(WorkbenchTheme.sidebar)
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkbenchTheme.border))
                                    .shadow(color: WorkbenchTheme.shadow, radius: 12, x: -4)
                                    .padding(6)
                            }
                        }

                }
                .padding(.horizontal, WorkbenchTheme.Island.margin).padding(.bottom, WorkbenchTheme.Island.margin)
                .background(WorkbenchTheme.frame)
                WorkspaceStatusBar()
                }
                .background(WorkbenchTheme.frame)
                .overlayPreferenceValue(SessionMenuAnchorKey.self) { anchor in
                    GeometryReader { geometry in
                        if model.sessionMenuVisible, let session = model.active, let anchor {
                            let rect = geometry[anchor]
                            ZStack(alignment: .topLeading) {
                                Color.clear.contentShape(Rectangle()).onTapGesture { closeSessionMenu() }
                                SessionActionMenu(session: session, close: closeSessionMenu)
                                    .offset(x: max(8, min(rect.maxX - 180, geometry.size.width - 188)), y: rect.maxY + 4)
                            }
                        }
                    }
                }
                .onChange(of: model.active?.id) { model.sessionMenuVisible = false }
                .ignoresSafeArea(.container, edges: .top)
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
        .onAppear {
            #if DEBUG
            if Bundle.main.bundleIdentifier == "local.claudemirror.demo",
               ProcessInfo.processInfo.environment["MIRROR_SCENE"] == "menu" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.sessionMenuVisible = true }
            }
            #endif
        }
        .onAppear { sidebarWidth = min(360, max(200, savedSidebarWidth)); ThemeStore.apply() }
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
                    .transition(Motion.card(reduce: reduceMotion))
            }
        }
        .animation(Motion.animation(Motion.dialogIn, reduce: reduceMotion), value: model.toast)
        // Keep every app dialog in the workspace, matching Winc's floating modal cards.
        .disabled(model.presentation != nil)
        .accessibilityHidden(model.presentation != nil)
        .overlay { WorkbenchPresentationLayer() }
        .onChange(of: model.presentation?.id) {
            if model.presentation == nil { model.focusWorkspace() }
        }
        .font(WorkbenchMetrics.ui)
        .buttonStyle(WorkbenchButtonStyle())
        .textFieldStyle(WorkbenchTextFieldStyle())
        .toggleStyle(WorkbenchToggleStyle())
    }
    private func closeSessionMenu() {
        model.sessionMenuVisible = false
        model.focusWorkspace()
    }
}
#endif
