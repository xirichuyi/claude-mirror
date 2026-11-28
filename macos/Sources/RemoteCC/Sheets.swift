#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

/// Only the permission mode is set here; anything left alone follows the remote Claude settings.
struct PreferencesSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var remoteMode: String?
    @State private var permissionMode = ""
    @State private var error = ""
    @State private var saving = false

    static let modes: [(String, String)] = [("default", "请求时确认"), ("plan", "计划"), ("acceptEdits", "自动编辑"),
                                            ("dontAsk", "拒绝未授权"), ("auto", "自动权限"), ("bypassPermissions", "Full Access")]
    static func label(_ mode: String?) -> String { modes.first { $0.0 == mode }?.1 ?? mode ?? "请求时确认" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeading(title: "权限") { dismiss() }.disabled(saving).padding(.horizontal, WorkbenchMetrics.dialogPadding).frame(height: WorkbenchMetrics.dialogHeader)
            WorkbenchSelect(title: "权限", selection: $permissionMode, options:
                [WorkbenchOption("", "远端默认 · " + Self.label(remoteMode ?? "default"))] +
                Self.modes.map { WorkbenchOption($0.0, $0.1) })
                .disabled(saving)
                .padding(.horizontal, WorkbenchMetrics.dialogPadding)
            HStack {
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { apply() }.buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(saving)
            }
            .padding()
        }
        .frame(width: 360)
        .task { await load() }
    }

    private func load() async {
        guard let engine = model.engine, let session = model.active else { return }
        let stored = session.preferences?.permissionMode ?? ""
        permissionMode = stored
        guard let defaults = try? await engine.agents.call(session.config, "file", ["operation": "claudeDefaults", "directory": .string(session.directory)], timeout: 10),
              case .string(let mode)? = defaults["permissionMode"] else { return }
        remoteMode = mode
    }

    private func apply() {
        guard let engine = model.engine, let session = model.active else { return }
        var next = session.preferences ?? Preferences()
        next.permissionMode = permissionMode.isEmpty ? nil : permissionMode
        saving = true; error = ""
        Task {
            do { try await engine.configure(session.id, next); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

struct CommandPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    let interaction: CommandInteraction
    @State private var value = ""
    @State private var custom = ""

    private var options: [CommandOption] {
        var list = interaction.options
        if interaction.kind == .model, let selected = interaction.selected, !list.contains(where: { $0.value == selected }) {
            list.append(CommandOption(value: selected, label: selected))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("/" + interaction.command).font(.headline)
            WorkbenchSelect(title: interaction.kind == .model ? "选择模型" : "选择参数", selection: $value,
                            options: options.map { WorkbenchOption($0.value, $0.label) })
            if interaction.kind == .model { TextField("或输入自定义模型 ID", text: $custom).textFieldStyle(WorkbenchTextFieldStyle()) }
            if let description = options.first(where: { $0.value == value })?.description ?? interaction.description {
                Text(description).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(interaction.kind == .model ? "切换模型" : "执行") {
                    let choice = custom.trimmingCharacters(in: .whitespaces)
                    model.applyCommandPicker(interaction, value: choice.isEmpty ? value : choice)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(value.isEmpty && custom.isEmpty)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear { value = interaction.selected ?? options.first?.value ?? "" }
    }
}

struct SessionToolsSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var localPort = ""
    @State private var remotePort = ""
    @State private var tunnels: [Tunnel] = []
    @State private var error = ""

    private let destinations = [("skills", "技能", "sparkles"), ("commands", "命令", "terminal"),
        ("mcp", "连接器", "point.3.connected.trianglepath.dotted"), ("plugins", "插件", "puzzlepiece.extension"),
        ("agents", "Agents", "person.2"), ("tasks", "后台任务", "checklist"),
        ("config", "记忆与配置", "doc.text"), ("models", "模型", "cpu"),
        ("tools", "工具", "wrench.and.screwdriver"), ("status", "会话状态", "info.circle"), ("ssh", "端口转发", "network")]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: destinations.first { $0.0 == model.sessionToolsSection }?.1 ?? "扩展与配置") { dismiss() }
                .padding(.horizontal, 20).frame(height: 52)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    ForEach(destinations, id: \.0) { item in
                        Button { model.sessionToolsSection = item.0 } label: {
                            Label { Text(item.1) } icon: { WorkbenchIcon(symbol: item.2) }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(SidebarNavigationStyle(selected: model.sessionToolsSection == item.0))
                    }
                    Spacer()
                }.padding(12).frame(width: 160).background(WorkbenchTheme.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    if let session = model.active {
                        if model.sessionToolsSection == "ssh" { portForwarding(session) }
                        else { ClaudeToolsView(sessionID: session.id, section: SessionToolSection(rawValue: model.sessionToolsSection) ?? .skills).id(session.id + ":" + model.sessionToolsSection) }
                    } else {
                        Text("打开对话后管理该项目的扩展和配置。").foregroundStyle(WorkbenchTheme.inkMuted)
                        Spacer()
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(width: 820, height: 600)
        .onAppear { if let session = model.active { tunnels = model.connections?.tunnels(session.config) ?? [] } }
    }

    private func portForwarding(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("本地端口", text: $localPort).frame(width: 110)
                TextField("远端端口", text: $remotePort).frame(width: 110)
                Button("转发") { forward(session) }.disabled(Int(localPort) == nil || Int(remotePort) == nil)
            }.textFieldStyle(WorkbenchTextFieldStyle())
            ForEach(tunnels) { tunnel in
                HStack {
                    Button("localhost:\(tunnel.localPort) → 远端 \(tunnel.remotePort)") {
                        if let url = URL(string: "http://127.0.0.1:\(tunnel.localPort)") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link)
                    Button("关闭") { close(tunnel, session) }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error) }
            Spacer()
        }
    }

    private func forward(_ session: ChatSession) {
        guard let local = Int(localPort), let remote = Int(remotePort), let connections = model.connections else { return }
        error = ""
        Task {
            do { try await connections.forward(session.config, Tunnel(localPort: local, remotePort: remote)); tunnels = connections.tunnels(session.config) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func close(_ tunnel: Tunnel, _ session: ChatSession) {
        guard let connections = model.connections else { return }
        Task {
            do { try await connections.forward(session.config, tunnel, remove: true); tunnels = connections.tunnels(session.config) }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
