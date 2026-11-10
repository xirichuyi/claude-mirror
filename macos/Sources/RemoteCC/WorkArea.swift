#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct WorkArea: View {
    @EnvironmentObject private var model: AppModel

    @State private var showingChat = false

    var body: some View {
        GeometryReader { geometry in
            let workspace = model.activeWorkspace
            let hasEditor = workspace?.activeTab != nil
            let hasFiles = model.showFiles && model.active != nil
            let hasWorkspace = hasEditor || hasFiles
            // Each area is its own card on the window frame, as in the reference layout.
            if !hasWorkspace {
                ChatView().islandCard()
            } else if geometry.size.width < 720 {
                VStack(spacing: 0) {
                    CapsulePicker(label: "显示区域", options: [true, false], selection: $showingChat) {
                        $0 ? "对话" : "工作区"
                    }.padding(10)
                    if showingChat { ChatView() }
                    else { workspacePane(workspace, hasFiles: hasFiles) }
                }.islandCard()
            } else {
                HStack(spacing: WorkbenchTheme.Island.gap) {
                    ChatView().frame(minWidth: 340, maxWidth: .infinity).islandCard()
                    if hasWorkspace {
                        if geometry.size.width >= 1080 {
                            if let workspace, hasEditor { EditorPane(workspace: workspace).frame(minWidth: 360, maxWidth: .infinity).islandCard() }
                            if hasFiles { FilePanel().frame(minWidth: 230, idealWidth: 260, maxWidth: 340).islandCard(WorkbenchTheme.sidebar) }
                        } else {
                            workspacePane(workspace, hasFiles: hasFiles).frame(minWidth: 320, maxWidth: .infinity).islandCard()
                        }
                    }
                }
            }
        }
        .onChange(of: model.activeWorkspace?.activeTabId) { showingChat = false }
        .onChange(of: model.showFiles) { if model.showFiles { showingChat = false } }
        .navigationTitle(model.active.map { historyDisplayTitle($0.name) } ?? "claude-mirror")
        .navigationSubtitle(model.active.map { ($0.directory as NSString).lastPathComponent + " · " + $0.host } ?? model.currentConfig?.displayName ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let session = model.active {
                    Menu {
                        Button("切换项目", systemImage: "folder") { model.openProjectPicker() }
                            .disabled(!model.isConnected)
                        Button("扩展与配置", systemImage: "puzzlepiece.extension") { model.openTools("skills") }
                        Button(model.showSessionDetails ? "收起会话详情" : "会话详情", systemImage: "sidebar.right") {
                            model.showSessionDetails.toggle()
                        }
                        Divider()
                        Button("对话选项", systemImage: "slider.horizontal.3") { model.showPreferences = true }
                        Button("同步消息", systemImage: "arrow.clockwise") { Task { await model.refreshVisibleHistory(session.id) } }
                            .disabled(!model.isConnected || session.isBusy || session.remoteOwner != nil || model.refreshingHistory.contains(session.id))
                        Button("订阅用量", systemImage: "chart.bar") { model.presentation = .accountUsage }
                        Button("对话用量与上下文", systemImage: "gauge.with.dots.needle.33percent") { model.showUsage = true }
                        Button("分支对话", systemImage: "arrow.triangle.branch") {
                            model.perform { if let fork = try model.engine?.fork(session.id) { model.select(fork.id) } }
                        }
                        Button("导出对话", systemImage: "square.and.arrow.up") { model.exportConversation(session) }
                    } label: { Label("更多", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .help("更多会话操作")
                    .accessibilityLabel("更多会话操作")
                    Button { model.showFiles.toggle() } label: { Label("文件", systemImage: "sidebar.right") }
                        .labelStyle(.iconOnly)
                        .help(model.showFiles ? "收起文件" : "打开文件")
                        .accessibilityLabel("文件")
                }
            }
        }
    }
    @ViewBuilder private func workspacePane(_ workspace: Workspace?, hasFiles: Bool) -> some View {
        if let workspace, workspace.activeTab != nil {
            if hasFiles {
                VSplitView {
                    FilePanel().frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
                    EditorPane(workspace: workspace).frame(minHeight: 200, maxHeight: .infinity)
                }
            } else { EditorPane(workspace: workspace) }
        } else if hasFiles { FilePanel() }
    }

}

func statusLabel(_ status: String) -> String {
    ["detached": "远端任务待同步", "idle": "就绪", "connecting": "连接中", "working": "正在回复", "permission": "等待你的确认", "stopping": "正在停止", "stopped": "已停止", "error": "调用未完成"][status] ?? status
}
#endif
