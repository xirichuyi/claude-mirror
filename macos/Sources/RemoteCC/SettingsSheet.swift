#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

/// Global preferences remain available without an active conversation.
struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = "主机"
    @State private var renaming: ConnectionConfig?
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "设置") { dismiss() }.padding(24)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 4) {
                    ForEach(["主机", "对话", "关于"], id: \.self) { title in
                        Button(title) { section = title }.buttonStyle(SidebarNavigationStyle(selected: section == title))
                    }
                }.frame(width: 100)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if section == "主机" { hosts }
                        else if section == "对话" { conversation }
                        else {
                            Text("claude mirror").font(.title2.weight(.semibold))
                            Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                                .foregroundStyle(.secondary)
                            Button(model.checkingForUpdates ? "正在检查…" : "检查更新") { Task { await model.checkForUpdates(manual: true) } }
                                .disabled(model.checkingForUpdates)
                                .buttonStyle(WorkbenchButtonStyle())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 640, height: 460)
        .alert("主机名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $name)
            Button("保存") {
                if let machine = renaming { model.renameMachine(machine, name: name) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SSH 主机").font(.headline)
                Spacer()
                Button("添加主机") { dismiss(); model.showConnect = true }.buttonStyle(WorkbenchButtonStyle())
            }
            ForEach(model.savedMachines, id: \.key) { machine in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(machine.displayName).font(.body.weight(.medium))
                            Text(machine.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重命名") { name = machine.displayName; renaming = machine }
                        if model.currentConfig?.key == machine.key && model.isConnected {
                            Button("断开") { model.disconnect() }
                        } else {
                            Button("连接") { model.selectMachine(machine) }
                        }
                    }
                    Toggle("允许远端访问本机", isOn: Binding(
                        get: { model.savedMachines.first { $0.key == machine.key }?.reverseAccess == true },
                        set: { model.setReverseAccess(machine, enabled: $0) }))
                        .help("允许这台服务器通过 SSH 以你的用户身份访问本机")
                    if machine.reverseAccess == true {
                        HStack {
                            Text(model.reverseStatus(machine)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("复制连接命令") { model.copyReverseCommand(machine) }
                                .disabled(model.reverseStates[machine.key]?.command == nil)
                        }
                    }
                }.padding(14).background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            if model.savedMachines.isEmpty { Text("尚未添加主机").foregroundStyle(.secondary) }
        }.buttonStyle(QuietButtonStyle())
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("当前对话").font(.headline)
            if let session = model.active {
                Text(historyDisplayTitle(session.name)).lineLimit(2).foregroundStyle(.secondary)
                Button("模型与权限") { dismiss(); model.showPreferences = true }
                Button("上下文与用量") { dismiss(); model.showUsage = true }
                Button("扩展与配置") { dismiss(); model.openTools("config") }
            } else {
                Text("打开对话后可调整模型和权限。").foregroundStyle(.secondary)
            }
        }.buttonStyle(WorkbenchButtonStyle())
    }
}
#endif
