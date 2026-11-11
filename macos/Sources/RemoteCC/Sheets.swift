#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct PreferencesSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var capabilities: Capabilities?
    @State private var loadError = ""
    @State private var agent = ""
    @State private var selectedModel = ""
    @State private var customModel = ""
    @State private var effort = ""
    @State private var permissionMode = "default"
    @State private var fastMode = false
    @State private var outputStyle = ""
    @State private var promptCacheTtl = ""
    @State private var directories = ""
    @State private var error = ""
    @State private var saving = false
    @State private var advanced = false

    private let customTag = "__custom__"
    private var currentModel: RemoteModel? { capabilities?.models.first { $0.value == (selectedModel.isEmpty ? "default" : selectedModel) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeading(title: "对话选项") { dismiss() }.disabled(saving).padding(.horizontal, WorkbenchMetrics.dialogPadding).frame(height: WorkbenchMetrics.dialogHeader)
            if let capabilities { form(capabilities).disabled(saving) }
            else if !loadError.isEmpty { Text(loadError).foregroundStyle(WorkbenchTheme.error).padding().textSelection(.enabled) }
            else { ProgressView("读取远端能力…").padding().frame(maxWidth: .infinity) }
            HStack {
                Button("刷新模型列表") { load(refresh: true) }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).lineLimit(2) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { apply() }.buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(capabilities == nil || saving)
            }
            .padding()
        }
        .frame(width: 440)
        .task { load(refresh: false) }
    }

    private func form(_ capabilities: Capabilities) -> some View {
        let session = model.active
        return VStack(alignment: .leading, spacing: 8) {
            WorkbenchSelect(title: "模型", selection: $selectedModel, options:
                [WorkbenchOption("", "远端默认")] + capabilities.models.filter { $0.value != "default" }.map { WorkbenchOption($0.value, $0.displayName ?? $0.value) } + [WorkbenchOption(customTag, "自定义模型 ID")])
            if selectedModel == customTag { TextField("模型 ID", text: $customModel) }
            WorkbenchSelect(title: "思考强度", selection: $effort, options:
                [WorkbenchOption("", "自动")] + ["low", "medium", "high", "xhigh", "max"].filter { currentModel == nil || currentModel?.supportedEffortLevels?.contains($0) == true }.map { WorkbenchOption($0, $0) })
            WorkbenchSelect(title: "权限", selection: $permissionMode, options: permissionOptions)
            DisclosureGroup("高级选项", isExpanded: $advanced) {
                WorkbenchSelect(title: "Agent", selection: $agent, options:
                    [WorkbenchOption("", "远端默认")] + (capabilities.agents ?? []).map { WorkbenchOption($0.name, $0.name) } +
                    (!agent.isEmpty && capabilities.agents?.contains(where: { $0.name == agent }) != true ? [WorkbenchOption(agent, agent + "（不可用）")] : []))
                .disabled(session?.messages.isEmpty == false)
                .help(session?.messages.isEmpty == false ? "请在新对话中选择 Agent" : capabilities.agents?.first { $0.name == agent }?.description ?? "")
                Toggle("快速模式", isOn: $fastMode).help("需要模型与账户支持").disabled(currentModel != nil && currentModel?.supportsFastMode != true)
                WorkbenchSelect(title: "输出样式", selection: $outputStyle, options:
                    [WorkbenchOption("", "远端默认")] + (capabilities.outputStyles ?? []).map { WorkbenchOption($0, $0) })
                WorkbenchSelect(title: "上下文缓存", selection: $promptCacheTtl, options:
                    [WorkbenchOption("", "远端默认"), WorkbenchOption("5m", "5 分钟"), WorkbenchOption("1h", "1 小时")])
                .disabled(session?.isBusy == true)
                .help("需要 Claude Code 2.1.242+。1 小时适合间歇工作，缓存写入费率更高；远端环境变量优先。不会发送保活请求。")
                VStack(alignment: .leading) {
                    Text("额外目录").help("每行一个远端绝对路径")
                    TextEditor(text: $directories).scrollContentBackground(.hidden).background(WorkbenchTheme.surface).font(.system(size: 12, design: .monospaced)).frame(height: 54).disabled(session?.isBusy == true)
                }
            }

        }
        .padding(.horizontal, WorkbenchMetrics.dialogPadding).padding(.bottom, WorkbenchMetrics.formRowGap)
        .scrollContentBackground(.hidden)
    }

    private var permissionOptions: [WorkbenchOption<String>] {
        var options = [WorkbenchOption("default", "默认 · 请求时确认"), WorkbenchOption("plan", "计划 · 不执行修改"),
                       WorkbenchOption("acceptEdits", "自动接受文件编辑"), WorkbenchOption("dontAsk", "拒绝未授权操作")]
        if currentModel == nil || currentModel?.supportsAutoMode == true { options.append(WorkbenchOption("auto", "自动判断权限")) }
        return options
    }

    private func load(refresh: Bool) {
        guard let engine = model.engine, let session = model.active else { loadError = "请先连接 SSH"; return }
        loadError = ""
        let preferences = session.preferences ?? Preferences()
        Task {
            do {
                let result = try await engine.capabilities(session.id, refresh: refresh)
                agent = preferences.agent ?? ""
                let selected = preferences.selectedModel ?? ""
                if selected.isEmpty || result.models.contains(where: { $0.value == selected }) { selectedModel = selected }
                else { selectedModel = customTag; customModel = selected }
                effort = preferences.effort ?? ""
                permissionMode = preferences.permissionMode ?? "default"
                fastMode = preferences.fastMode ?? false
                outputStyle = preferences.outputStyle ?? ""
                promptCacheTtl = preferences.promptCacheTtl ?? ""
                directories = (preferences.additionalDirectories ?? []).joined(separator: "\n")
                capabilities = result
            } catch { loadError = error.localizedDescription }
        }
    }

    private func apply() {
        guard let engine = model.engine, let session = model.active else { return }
        var next = session.preferences ?? Preferences()
        next.agent = agent
        next.selectedModel = selectedModel == customTag ? customModel.trimmingCharacters(in: .whitespaces) : selectedModel
        next.effort = effort; next.permissionMode = permissionMode; next.fastMode = fastMode; next.outputStyle = outputStyle
        next.promptCacheTtl = promptCacheTtl
        next.additionalDirectories = directories.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
