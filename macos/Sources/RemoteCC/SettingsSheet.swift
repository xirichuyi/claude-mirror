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
    @AppStorage(ThemeStore.modeKey) private var themeMode = ThemeStore.Mode.system.rawValue
    @AppStorage(ThemeStore.darkKey) private var darkTheme = ThemePalette.midnight.id
    @AppStorage(ThemeStore.lightKey) private var lightTheme = ThemePalette.daylight.id

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "设置") { dismiss() }.padding(24)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 4) {
                    ForEach(["主机", "对话", "外观", "关于"], id: \.self) { title in
                        Button(title) { section = title }.buttonStyle(SidebarNavigationStyle(selected: section == title))
                    }
                }.frame(width: 100)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if section == "主机" { hosts }
                        else if section == "对话" { conversation }
                        else if section == "外观" { appearance }
                        else {
                            Text("claude mirror").font(.title2.weight(.semibold))
                            Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                                .foregroundStyle(WorkbenchTheme.inkMuted)
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
                            Text(machine.host).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
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
                        .toggleStyle(.switch).controlSize(.mini)
                    if machine.reverseAccess == true {
                        HStack {
                            Text(model.reverseStatus(machine)).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                            Spacer()
                            Button("复制连接命令") { model.copyReverseCommand(machine) }
                                .disabled(model.reverseStates[machine.key]?.command == nil)
                        }
                    }
                }.padding(14).background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
            }
            if model.savedMachines.isEmpty { Text("尚未添加主机").foregroundStyle(WorkbenchTheme.inkMuted) }
        }.buttonStyle(QuietButtonStyle())
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("外观").font(.headline)
            CapsulePicker(label: "外观模式", options: ThemeStore.Mode.allCases, selection: Binding(
                get: { ThemeStore.Mode(rawValue: themeMode) ?? .system },
                set: { themeMode = $0.rawValue; ThemeStore.apply() })) { mode in
                switch mode { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
            }.frame(maxWidth: 320)
            themeRow("深色主题", palettes: ThemePalette.all.filter(\.dark), selection: $darkTheme)
            themeRow("浅色主题", palettes: ThemePalette.all.filter { !$0.dark }, selection: $lightTheme)
            Text("配色改编自 winc（Apache-2.0）：正文对比度不低于 7:1，次要文字不低于 4.5:1。")
                .font(.caption).foregroundStyle(WorkbenchTheme.inkDim)
        }
    }

    private func themeRow(_ title: String, palettes: [ThemePalette], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(WorkbenchTheme.inkMuted)
            HStack(spacing: 12) {
                ForEach(palettes) { palette in
                    ThemeSwatch(palette: palette, selected: selection.wrappedValue == palette.id) { selection.wrappedValue = palette.id }
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("当前对话").font(.headline)
            if let session = model.active {
                Text(historyDisplayTitle(session.name)).lineLimit(2).foregroundStyle(WorkbenchTheme.inkMuted)
                Button("模型与权限") { dismiss(); model.showPreferences = true }
                Button("上下文与用量") { dismiss(); model.showUsage = true }
                Button("扩展与配置") { dismiss(); model.openTools("config") }
            } else {
                Text("打开对话后可调整模型和权限。").foregroundStyle(WorkbenchTheme.inkMuted)
            }
        }.buttonStyle(WorkbenchButtonStyle())
    }
}

/// A miniature of the palette: frame, card, a selected row and a few highlighted code lines.
private struct ThemeSwatch: View {
    let palette: ThemePalette
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Color(nsColor: palette.frame)
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: palette.card)).frame(width: 26)
                            .overlay(alignment: .top) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: palette.selected)).frame(height: 6).padding(4)
                            }
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: palette.card))
                            .overlay(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 4) {
                                    bar([(palette.syntax.keyword, 10), (palette.syntax.function, 18), (palette.syntax.text, 8)])
                                    bar([(palette.syntax.builtin, 14), (palette.syntax.string, 22)])
                                    bar([(palette.syntax.comment, 30)])
                                    bar([(palette.syntax.number, 8), (palette.syntax.property, 16)])
                                }.padding(6)
                            }
                    }.padding(4)
                }
                .frame(width: 104, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? WorkbenchTheme.accent : WorkbenchTheme.border, lineWidth: selected ? 2 : 1))
                Text(palette.name).font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func bar(_ parts: [(NSColor, CGFloat)]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Capsule().fill(Color(nsColor: part.0)).frame(width: part.1, height: 3)
            }
        }
    }
}
#endif
