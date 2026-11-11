#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

/// Global preferences remain available without an active conversation.
struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var section = "主机"
    @AppStorage(ThemeStore.modeKey) private var themeMode = ThemeStore.Mode.system.rawValue
    @AppStorage(ThemeStore.darkKey) private var darkTheme = ThemePalette.midnight.id
    @AppStorage(ThemeStore.lightKey) private var lightTheme = ThemePalette.daylight.id

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Image(systemName: "slider.horizontal.3"); Text("设置").fontWeight(.semibold) }
                    .foregroundStyle(WorkbenchTheme.inkMuted).frame(height: 52).padding(.horizontal, 12)
                ForEach(sections, id: \.title) { item in
                    Button { section = item.title } label: {
                        Label { Text(item.title) } icon: { WorkbenchIcon(symbol: item.icon) }.frame(height: 24)
                    }.buttonStyle(SidebarNavigationStyle(selected: section == item.title))
                }
                Spacer()
            }.padding(.horizontal, 10).frame(width: 180).background(WorkbenchTheme.frame)
            VStack(spacing: 0) {
                SheetHeading(title: section) { dismiss() }
                    .padding(.horizontal, 24).frame(height: 52)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if section == "主机" { hosts }
                        else if section == "对话" { conversation }
                        else if section == "外观" { appearance }
                        else if section == "快捷键" { shortcuts }
                        else { about }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24).padding(.top, 4)
                    .id(section)
                }
            }.frame(maxWidth: .infinity)
        }.frame(width: 720, height: 520)
        .onAppear {
            #if DEBUG
            if Bundle.main.bundleIdentifier == "local.claudemirror.demo",
               let requested = ProcessInfo.processInfo.environment["MIRROR_SETTINGS_SECTION"],
               sections.contains(where: { $0.title == requested }) { section = requested }
            #endif
        }
    }

    private let sections = [(title: "主机", icon: "server.rack"), (title: "对话", icon: "bubble.left.and.bubble.right"),
                            (title: "外观", icon: "paintpalette"), (title: "快捷键", icon: "keyboard"), (title: "关于", icon: "info.circle")]

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) { BrandIcon(size: 32); Text("Claude Mirror").font(.system(size: 20, weight: .semibold)) }
            Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                .foregroundStyle(WorkbenchTheme.inkMuted)
            Text("通过 SSH 连接你的代码与 Claude。").foregroundStyle(WorkbenchTheme.inkMuted)
            Button(model.checkingForUpdates ? "正在检查…" : "检查更新") { Task { await model.checkForUpdates(manual: true) } }
                .disabled(model.checkingForUpdates)
            Divider().padding(.vertical, 8)
            Text("界面设计改编自 Winc").fontWeight(.medium)
            Text("Copyright 2026 Chenyme and DEEIX AI · Apache License 2.0")
                .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            Link("Winc 源码与许可证", destination: URL(string: "https://github.com/DEEIX-AI/Winc")!)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工作区").font(.headline).padding(.bottom, 12)
            ForEach([("新建对话", "⌘ N"), ("快速打开 / 命令", "⌘ P"), ("保存文件", "⌘ S"),
                     ("关闭文件标签", "⌘ W"), ("在项目中搜索", "⇧ ⌘ F"), ("切换侧边栏", "⌘ B"), ("显示文件面板", "⇧ ⌘ E"),
                     ("设置", "⌘ ,")], id: \.0) { action, keys in
                HStack { Text(action); Spacer(); WorkbenchShortcut(keys: keys) }
                    .padding(.horizontal, 12).frame(height: 38)
                Divider()
            }
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
                        Button("编辑") { model.presentation = .editMachine(machine) }
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
                        .toggleStyle(WorkbenchToggleStyle()).controlSize(.mini)
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
            CapsulePicker(label: "外观模式", options: ThemeStore.Mode.allCases, selection: Binding(
                get: { ThemeStore.Mode(rawValue: themeMode) ?? .system },
                set: { themeMode = $0.rawValue; ThemeStore.apply() })) { mode in
                switch mode { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
            }.frame(maxWidth: 320)
            themeRow("深色主题", palettes: ThemePalette.all.filter(\.dark), selection: $darkTheme)
            themeRow("浅色主题", palettes: ThemePalette.all.filter { !$0.dark }, selection: $lightTheme)
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
                Button("会话详情") { dismiss(); model.showSessionDetails = true }
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
