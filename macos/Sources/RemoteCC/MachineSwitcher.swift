#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct MachineSwitcher: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @State private var choosing = false
    var body: some View {
        Button { choosing.toggle() } label: {
            // Keep the current host visible beside its connection status.
            HStack(spacing: 7) {
                Circle().fill(model.isConnected ? WorkbenchTheme.sage : WorkbenchTheme.inkMuted.opacity(0.5)).frame(width: 7, height: 7)
                if compact {
                    WorkbenchIcon(symbol: "desktopcomputer").font(.system(size: 18))
                } else {
                    Text(model.currentConfig?.displayName ?? "选择机器").font(.headline).lineLimit(1)
                    WorkbenchIcon(symbol: "chevron.up.chevron.down").font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).help("当前机器：" + (model.currentConfig?.displayName ?? "未连接") + " · 切换或添加机器")
        .accessibilityLabel("切换主机")
        .popover(isPresented: $choosing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Button { choosing = false; model.activeId = nil } label: { Label("返回首页", systemImage: "house") }.buttonStyle(QuietButtonStyle())
                Divider()
                Text("我的机器").font(.subheadline.weight(.medium)).foregroundStyle(WorkbenchTheme.inkMuted).padding(8)
                ForEach(model.savedMachines, id: \.key) { machine in
                    Button {
                        choosing = false
                        model.selectMachine(machine)
                    } label: {
                        HStack(spacing: 10) {
                            WorkbenchIcon(symbol: "desktopcomputer")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(machine.displayName)
                                Text(machine.host + (machine.port.map { ":\($0)" } ?? "")).font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted)
                            }
                            Spacer()
                            if model.currentConfig?.key == machine.key { WorkbenchIcon(symbol: "checkmark") }
                            Circle().fill(model.engine?.connectionState(machine).status == .connected ? WorkbenchTheme.added : WorkbenchTheme.inkMuted).frame(width: 6, height: 6)
                        }.font(.body).padding(4).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle())
                    .contextMenu {
                        Button("编辑机器…") { choosing = false; model.presentation = .editMachine(machine) }

                        Button("重命名…") {
                            choosing = false
                            model.presentation = .rename(WorkbenchRename(title: "主机名称", initial: machine.displayName) { model.renameMachine(machine, name: $0) })
                        }
                        Divider()
                        Toggle("允许此服务器反向连接本机", isOn: Binding(
                            get: { machine.reverseAccess == true },
                            set: { model.setReverseAccess(machine, enabled: $0) }))
                        if machine.reverseAccess == true {
                            Text(model.reverseStatus(machine))
                            Button("复制反向连接命令") { model.copyReverseCommand(machine) }
                                .disabled(model.reverseStates[machine.key]?.command == nil)
                        }
                    }
                }
                Divider()
                Button { choosing = false; model.showSettings = true } label: {
                    Label("管理主机…", systemImage: "gearshape")
                }.buttonStyle(QuietButtonStyle())
                Button { choosing = false; model.showConnect = true } label: {
                    Label("添加机器…", systemImage: "plus").font(.body).padding(10)
                }.buttonStyle(.plain)
            }.padding(8).frame(width: 260).workbenchPanel()
        }
    }
}
#endif
