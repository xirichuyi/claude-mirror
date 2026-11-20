#if canImport(SwiftUI)
    import SwiftUI
    import AppKit
    import RemoteCCCore

    struct MachineSwitcher: View {
        @EnvironmentObject private var model: AppModel
        @State private var choosing = false
        var body: some View {
            Button {
                choosing.toggle()
            } label: {
                // Keep the current host visible beside its connection status.
                HStack(spacing: 4) {
                    Circle().fill(model.isConnected ? WorkbenchTheme.sage : WorkbenchTheme.inkMuted.opacity(0.5)).frame(
                        width: 6, height: 6)
                    Text(model.currentConfig?.displayName ?? "选择机器")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    WorkbenchIcon(symbol: "chevron.down").scaleEffect(0.7).frame(width: 12)
                        .foregroundStyle(WorkbenchTheme.inkMuted)
                }
                .padding(.horizontal, 2).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help("当前机器：" + (model.currentConfig?.displayName ?? "未连接") + " · 切换或添加机器")
                .accessibilityLabel("切换主机")
                .workbenchPopup(isPresented: $choosing) {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(model.savedMachines, id: \.key) { machine in
                                    machineRow(machine)
                                }
                            }
                        }.frame(
                            height: min(
                                CGFloat(model.savedMachines.count) * WorkbenchMetrics.row, WorkbenchMetrics.row * 8))
                        Rectangle().fill(WorkbenchTheme.separator).frame(height: 1).padding(.horizontal, 6).padding(
                            .vertical, 5)
                        Button {
                            choosing = false
                            model.showConnect = true
                        } label: {
                            Text("添加服务器…").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(QuietButtonStyle(height: WorkbenchMetrics.row))
                        Button {
                            choosing = false
                            model.showSettings = true
                        } label: {
                            Text("管理主机…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(QuietButtonStyle(height: WorkbenchMetrics.row))
                    }.padding(5).frame(width: 190).workbenchPanel()
                }
        }

        private func machineRow(_ machine: ConnectionConfig) -> some View {
            let selected = model.currentConfig?.key == machine.key
            let connected = model.engine?.connectionState(machine).status == .connected
            return Button {
                choosing = false
                if !selected { model.selectMachine(machine) }
            } label: {
                HStack(spacing: 6) {
                    WorkbenchIcon(symbol: "desktopcomputer")
                        .foregroundStyle(WorkbenchTheme.inkMuted).frame(width: 18)
                    Text(machine.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    WorkbenchIcon(symbol: "checkmark").foregroundStyle(WorkbenchTheme.accent)
                        .opacity(selected ? 1 : 0).frame(width: 14)
                }.font(WorkbenchMetrics.ui).frame(maxWidth: .infinity).frame(height: WorkbenchMetrics.row)
            }
            .buttonStyle(QuietButtonStyle(height: WorkbenchMetrics.row))
            .help(machine.host + (connected ? " · 已连接" : " · 未连接"))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

    }
#endif
