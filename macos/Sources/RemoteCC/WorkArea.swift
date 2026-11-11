#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct WorkArea: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("workspace.splitEditor") private var splitEditor = true

    @State private var splitFraction: CGFloat = 0.5
    @State private var dragFraction: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let workspace = model.activeWorkspace
            let hasEditor = workspace?.activeTab != nil
            let split = splitEditor && hasEditor && geometry.size.width >= 720
            let chatVisible = split || model.showingChat || !hasEditor
            let minimum = min(0.5, 300 / max(1, geometry.size.width - 6))
            let fraction = min(1 - minimum, max(minimum, splitFraction))
            VStack(spacing: 0) {
                if !split {
                    if hasEditor { tabs(workspace, hasEditor: true) }
                    else { conversationHeader(hasEditor: false) }
                }
                RetainedPaneLayout(selection: chatVisible ? 0 : 1, split: split, fraction: fraction) {
                    VStack(spacing: 0) {
                        if split { conversationHeader(hasEditor: true) }
                        ChatView()
                    }
                    .background(WorkbenchTheme.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: split ? 10 : 0))
                    .paneVisible(chatVisible)
                    if let workspace {
                        EditorPane(workspace: workspace, showsTabs: split)
                            .islandCard().paneVisible(split || !chatVisible)
                    }
                }
                .clipped()
                .overlay(alignment: .leading) {
                    if split {
                        splitHandle(width: geometry.size.width, fraction: fraction)
                    }
                }
            }
            .islandCard()

        }
        .onChange(of: model.activeWorkspace?.activeTabId) {
            model.showingChat = model.activeWorkspace?.activeTab == nil
        }
        .onChange(of: model.activeId) { model.focusChat() }
        .navigationTitle(model.active.map { historyDisplayTitle($0.name) } ?? "claude-mirror")
        .navigationSubtitle(model.currentConfig?.displayName ?? "")
    }

    private func splitHandle(width: CGFloat, fraction: CGFloat) -> some View {
        let available = max(1, width - 6)
        return Rectangle().fill(WorkbenchTheme.separator)
            .frame(width: 1).frame(maxHeight: .infinity)
            .frame(width: 6).contentShape(Rectangle())
            .offset(x: (available * fraction).rounded())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragFraction == nil { dragFraction = fraction }
                    let minimum = min(0.5, 300 / available)
                    splitFraction = min(1 - minimum, max(minimum, (dragFraction ?? splitFraction) + value.translation.width / available))
                }
                .onEnded { _ in dragFraction = nil })
            .accessibilityElement().accessibilityLabel("调整聊天与代码宽度")
            .accessibilityAdjustableAction { direction in
                let minimum = min(0.5, 300 / available)
                switch direction {
                case .increment: splitFraction = min(1 - minimum, splitFraction + 0.05)
                case .decrement: splitFraction = max(minimum, splitFraction - 0.05)
                @unknown default: break
                }
            }
    }

    private func conversationHeader(hasEditor: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.active.map { historyDisplayTitle($0.name) } ?? "新对话")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let session = model.active,
                   session.isBusy || session.runningBackgroundTaskCount > 0 || session.transportError != nil {
                    Button { model.showActivity = true } label: {
                        Text(model.activityLabel(session)).font(.system(size: 10))
                    }.buttonStyle(.plain).foregroundStyle(WorkbenchTheme.inkMuted)
                        .help("查看远端任务")
                }
            }
            Spacer(minLength: 4)
            if let count = model.activeWorkspace?.gitStatus?.files.count, count > 0 {
                Button {
                    model.panel = .changes; model.showFiles = true
                } label: { Label("\(count) 项变更", systemImage: "arrow.triangle.branch").font(.system(size: 11)) }
                    .buttonStyle(QuietButtonStyle()).help("审查当前项目变更")
            }
            if hasEditor {
                Button { splitEditor = false; model.focusChat() } label: { WorkbenchIcon(symbol: "sidebar.right") }
                    .buttonStyle(WorkbenchIconButtonStyle()).help("收起代码面板").accessibilityLabel("收起代码面板")
            }
        }.padding(.horizontal, 12).frame(height: 40)
    }

    private func tabs(_ workspace: Workspace?, hasEditor: Bool) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { model.focusChat() } label: {
                        Label(model.active.map { historyDisplayTitle($0.name) } ?? "新对话", systemImage: "bubble.left")
                            .lineLimit(1).frame(maxWidth: 220)
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(model.showingChat ? WorkbenchTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help("显示对话")
                    if let workspace {
                        ForEach(workspace.tabs) { tab in
                            EditorTabButton(tab: tab, active: !model.showingChat && tab.id == workspace.activeTabId,
                                select: { model.showingChat = false; Task { await workspace.select(tab) } },
                                close: { model.close(tab, in: workspace) })
                        }
                    }
                }.padding(.horizontal, 7)
            }
            Button { splitEditor.toggle() } label: {
                WorkbenchIcon(symbol: "rectangle.split.2x1")
                    .foregroundStyle(splitEditor ? WorkbenchTheme.accent : WorkbenchTheme.inkMuted)
            }.buttonStyle(WorkbenchIconButtonStyle()).disabled(!hasEditor)
                .help(splitEditor ? "切换为单栏（仅此按钮改变布局）" : "并排查看对话与文件")
                .accessibilityLabel(splitEditor ? "切换为单栏" : "并排查看对话与文件")
                .accessibilityAddTraits(splitEditor ? .isSelected : [])
                .padding(.trailing, 7)
        }.frame(height: 40)
    }
}

func statusLabel(_ status: String) -> String {
    ["detached": "远端任务待同步", "idle": "就绪", "connecting": "连接中", "working": "正在回复", "permission": "等待你的确认", "stopping": "正在停止", "stopped": "已停止", "error": "调用未完成"][status] ?? status
}
#endif
