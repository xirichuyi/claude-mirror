import RemoteCCCore
import SwiftUI

struct HostSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var removingHost: String?
    @State private var deletingHost = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SSH 主机").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                Spacer()
                Button {
                    model.showConnect = true
                } label: {
                    WorkbenchIcon(symbol: "plus")
                }
                .buttonStyle(WorkbenchIconButtonStyle()).help("添加服务器").accessibilityLabel("添加服务器")
            }.padding(.bottom, WorkbenchMetrics.formRowGap)
            ForEach(model.savedMachines, id: \.key) { machine in
                hostRow(machine)
                Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            }
            if model.savedMachines.isEmpty {
                Text("尚未添加主机").foregroundStyle(WorkbenchTheme.inkMuted).padding(.vertical, 16)
            }
        }
    }

    private func hostRow(_ machine: ConnectionConfig) -> some View {
        let connected = model.engine?.connectionState(machine).status == .connected
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WorkbenchIcon(symbol: "desktopcomputer").foregroundStyle(WorkbenchTheme.inkMuted)
                    .frame(width: 24, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.displayName).font(WorkbenchMetrics.ui).lineLimit(1)
                    if machine.displayName != machine.host {
                        Text(machine.host).font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Circle().fill(connected ? WorkbenchTheme.sage : WorkbenchTheme.inkDim)
                    .frame(width: 6, height: 6).help(connected ? "已连接" : "未连接")
                Button {
                    model.presentation = .editMachine(machine)
                } label: {
                    WorkbenchIcon(symbol: "square.and.pencil")
                }
                .buttonStyle(WorkbenchIconButtonStyle()).help("编辑服务器").accessibilityLabel("编辑 " + machine.displayName)
                if model.currentConfig?.key == machine.key && model.isConnected {
                    Button("断开") { model.disconnect() }.buttonStyle(QuietButtonStyle())
                } else {
                    Button("连接") { model.selectMachine(machine) }.buttonStyle(QuietButtonStyle())
                }
                Button {
                    removingHost = machine.key
                } label: {
                    WorkbenchIcon(symbol: "trash")
                }
                .buttonStyle(WorkbenchIconButtonStyle()).help("删除主机").accessibilityLabel("删除 " + machine.displayName)
            }.frame(minHeight: 36)
            if removingHost == machine.key {
                HStack(spacing: 8) {
                    Text("移除连接，保留聊天和远端文件。").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                    Spacer(minLength: 0)
                    Button("取消") { removingHost = nil }.buttonStyle(QuietButtonStyle())
                    Button(deletingHost ? "删除中…" : "删除") {
                        deletingHost = true
                        Task { @MainActor in
                            defer { deletingHost = false }
                            do {
                                try await model.removeMachine(machine)
                                removingHost = nil
                            } catch { model.show(error.localizedDescription) }
                        }
                    }.buttonStyle(QuietButtonStyle()).foregroundStyle(WorkbenchTheme.error)
                }.disabled(deletingHost).padding(.leading, 34)
            }
            DisclosureGroup("访问选项") {
                Toggle(
                    "允许远端访问本机",
                    isOn: Binding(
                        get: { model.savedMachines.first { $0.key == machine.key }?.reverseAccess == true },
                        set: { model.setReverseAccess(machine, enabled: $0) })
                )
                .help("允许这台服务器通过 SSH 以你的用户身份访问本机")
                .toggleStyle(WorkbenchToggleStyle())
                if machine.reverseAccess == true {
                    HStack {
                        Text(model.reverseStatus(machine)).font(WorkbenchMetrics.caption).foregroundStyle(
                            WorkbenchTheme.inkMuted)
                        Spacer()
                        Button("复制连接命令") { model.copyReverseCommand(machine) }
                            .disabled(model.reverseStates[machine.key]?.command == nil)
                    }
                }
            }.font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(.leading, 34)
        }.padding(.vertical, 12)
    }

}
