import AppKit
import RemoteCCCore
import SwiftUI

struct RemoteSetupSheet: View {
    let machine: ConnectionConfig
    @EnvironmentObject private var model: AppModel
    @State private var lines: [String] = []
    @State private var running = false
    @State private var result: Int32?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeading(title: "设置 \(machine.displayName)") { close() }.disabled(running)
            Text("会在服务器上安装缺少的 Claude Code 和 Node.js，全部装在你的用户目录，不需要管理员权限，也不会读取或修改 Claude 的登录信息。通常需要 1–3 分钟。")
                .font(.callout).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("==>") ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading).id(index)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity).frame(height: 220)
                .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
                .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            if let result {
                Label(
                    RemoteInstaller.summary(result),
                    systemImage: result == 0 ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.callout).foregroundStyle(result == 0 ? WorkbenchTheme.ink : WorkbenchTheme.error)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("正在安装…").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                Spacer()
                if running {
                    Button("停止") { task?.cancel() }
                } else {
                    Button("关闭") { close() }.keyboardShortcut(.cancelAction)
                    Button(result == nil ? "开始安装" : "重新安装") { start() }
                        .buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(running)
        .onDisappear { task?.cancel() }
    }

    private func close() {
        model.presentation = nil
        if result == 0 { model.recheckMachine(machine) }
    }

    private func start() {
        guard let engine = model.engine, let script = engine.agents.resources.installScript else {
            lines = ["应用内缺少安装脚本，请更新到最新版本。"]
            result = 1
            return
        }
        running = true
        result = nil
        lines = []
        task = Task {
            do {
                let code = try await RemoteInstaller.run(
                    launcher: engine.agents.launcher, config: machine, script: script
                ) { line in
                    Task { @MainActor in lines.append(line) }
                }
                await Task.yield()
                result = code
            } catch {
                lines.append(ConnectionAdvice.explain(error.localizedDescription))
                result = 1
            }
            running = false
            if result == 0 { model.recheckMachine(machine) }
        }
    }
}
