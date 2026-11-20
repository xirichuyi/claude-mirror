#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

/// Persistent setup checklist for the current machine. It stays until the problem is fixed,
/// unlike a toast, and each item carries the action that fixes it.
struct MachineHealthBanner: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    private var config: ConnectionConfig? { model.currentConfig }

    var body: some View {
        if let config, model.isConnected, let issues = model.machineHealth[config.key], !issues.isEmpty {
            let shown = compact ? issues.filter(\.blocking) : issues
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shown) { issue in row(issue, config: config) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(WorkbenchTheme.warning.opacity(0.35)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("服务器设置提醒")
                .padding(compact ? EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16) : EdgeInsets())
            }
        }
    }

    @ViewBuilder
    private func row(_ issue: HealthIssue, config: ConnectionConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: issue.blocking ? "exclamationmark.triangle" : "info.circle")
                .font(.callout.weight(.semibold))
            if !compact {
                Text(issue.detail).font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                switch issue.action {
                case .install:
                    Button("一键安装") { model.openRemoteSetup(config) }.buttonStyle(WorkbenchButtonStyle(prominent: true))
                case .login(let command):
                    Button("在终端登录") { model.runInTerminal(config, command: command) }.buttonStyle(WorkbenchButtonStyle(prominent: true))
                    Button("复制登录命令") { model.copyCommand(command, note: "已复制，SSH 登录服务器后运行即可") }
                case .copy(let command):
                    Button("复制命令") { model.copyCommand(command, note: "已复制，请在服务器上运行；如提示权限不足，请联系管理员") }
                case nil:
                    EmptyView()
                }
                Button {
                    model.recheckMachine(config)
                } label: {
                    if model.checkingHealth.contains(config.key) { ProgressView().controlSize(.mini) } else { Text("重新检查") }
                }.disabled(model.checkingHealth.contains(config.key))
            }
        }
    }
}

/// Shown on the machine page when the last connection attempt failed, with the explained reason.
struct ConnectionFailureNotice: View {
    @EnvironmentObject private var model: AppModel
    let config: ConnectionConfig
    let error: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("无法连接 \(config.displayName)", systemImage: "wifi.exclamationmark").font(.callout.weight(.semibold))
            Text(ConnectionAdvice.explain(error)).font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 8) {
                Button("重试") { model.perform { try await model.connect(config) } }.buttonStyle(WorkbenchButtonStyle(prominent: true))
                Button("修改连接设置") { model.presentation = .editMachine(config) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.error.opacity(0.06), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(WorkbenchTheme.error.opacity(0.3)))
    }
}
#endif
