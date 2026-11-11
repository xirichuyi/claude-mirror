#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct HistorySyncButton: View {
    @EnvironmentObject private var model: AppModel

    private var syncing: Bool {
        guard let config = model.currentConfig else { return false }
        return model.syncingMachines.contains(config.key)
    }

    var body: some View {
        Button {
            if let config = model.currentConfig { Task { await model.discoverHistory(config) } }
        } label: {
            ZStack {
                WorkbenchIcon(symbol: "arrow.clockwise").opacity(syncing ? 0 : 1)
                if syncing { ProgressView().controlSize(.mini) }
            }.frame(width: 16, height: 16)
        }
        .buttonStyle(WorkbenchIconButtonStyle())
        .disabled(!model.isConnected || syncing)
        .accessibilityLabel(syncing ? "正在同步会话" : "同步会话")
        .help("同步会话 · " + (model.connectionState.error.isEmpty ? model.historyStatus : model.connectionState.error))
    }
}

struct ServerFooter: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 2) {
            Button { model.showArchived.toggle() } label: {
                Label(model.showArchived ? "全部对话" : "归档", systemImage: "archivebox")
            }.buttonStyle(SidebarNavigationStyle(selected: model.showArchived))
        }.padding(.horizontal, 10).padding(.bottom, 8)
    }
}

struct ConnectSheet: View {
    var machine: ConnectionConfig? = nil
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var host = ""
    @State private var port = ""
    @State private var name = ""
    @State private var username = ""
    @State private var identityFile = ""
    @State private var password = ""
    @State private var authentication = SSHAuthentication.password
    @State private var showAdvanced = false
    @State private var error = ""
    @State private var connecting = false
    @FocusState private var focusedField: String?

    private var authenticationNote: String {
        switch authentication {
        case .password: return "密码只用于这次连接，不会保存。连接成功后可以一键设置免密登录。"
        case .keyFile: return "使用所选私钥登录，私钥不会上传。"
        case .automatic: return "使用这台 Mac 的 ~/.ssh/config、默认密钥和 SSH Agent，适合已经能在终端里 ssh 登录的服务器。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SheetHeading(title: machine == nil ? "添加服务器" : "编辑服务器") { dismiss() }.disabled(connecting)
                Text("填写服务器地址和登录方式。Claude Code 和项目都在服务器上运行，本机只负责显示和操作。")
                    .font(.body).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                connectionField("服务器地址", text: $host, prompt: "例如 192.168.1.10、ubuntu@example.com")
                WorkbenchSelect(title: "登录方式", selection: $authentication, options: [
                    WorkbenchOption(.password, "密码"), WorkbenchOption(.keyFile, "私钥文件"), WorkbenchOption(.automatic, "本机 SSH 配置")])
                if authentication == .password {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("密码").font(.callout.weight(.medium))
                        SecureField("服务器登录密码", text: $password)
                            .textFieldStyle(.plain).font(WorkbenchMetrics.ui).padding(8)
                            .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
                    }
                }
                if authentication == .keyFile {
                    HStack {
                        Text(identityFile.isEmpty ? "尚未选择私钥" : identityFile)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("选择私钥…") {
                            let panel = NSOpenPanel()
                            panel.showsHiddenFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                            if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
                        }
                    }
                }
                Text(authenticationNote)
                    .font(.subheadline).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 16) {
                        connectionField("显示名称", text: $name, prompt: "例如：开发服务器（可选）")
                        HStack {
                            connectionField("用户名", text: $username, prompt: "地址里没写时填写")
                            connectionField("端口", text: $port, prompt: "默认 22")
                        }
                    }.padding(.top, 12)
                } label: {
                    Text("高级选项：名称、用户名、端口").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
                }
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(WorkbenchTheme.error).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if connecting {
                    ProgressView().controlSize(.small)
                    Text("正在连接，首次连接可能需要确认服务器指纹…").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WorkbenchButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(connecting)
                Button(connecting ? "连接中…" : machine == nil ? "连接" : "保存并重连") { connect() }
                    .buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(connecting || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (authentication == .keyFile && identityFile.isEmpty)
                              || (authentication == .password && password.isEmpty && machine == nil))
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(connecting)
        .onAppear {
            guard let machine else { return }
            host = machine.host
            port = machine.port.map(String.init) ?? ""
            name = machine.name ?? ""
            identityFile = machine.identityFile ?? ""
            authentication = machine.authentication ?? .automatic
            showAdvanced = !port.isEmpty || !name.isEmpty
        }
        .task { await Task.yield(); focusedField = "服务器地址" }
        .onChange(of: authentication) { _, _ in password = "" }
        .onDisappear { password = "" }
    }

    private func connectionField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout.weight(.medium))
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.plain).focused($focusedField, equals: label)
                .font(WorkbenchMetrics.ui).padding(8)
                .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
        }
    }

    private func connect() {
        connecting = true; error = ""
        Task {
            do {
                let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard user.isEmpty || !address.contains("@") else { throw RemoteError("地址里已经写了用户名，请清空“高级选项”里的用户名") }
                guard user.isEmpty || (!user.contains("@") && !user.contains(":")) else { throw RemoteError("用户名不能包含 @ 或冒号") }
                let destination = user.isEmpty ? address : user + "@" + address
                // Reverse access is turned on from the machine's settings, never while adding it.
                let config = ConnectionConfig(host: destination, port: try ConnectionConfig.parsePort(port), directory: "~",
                                              name: name, identityFile: authentication == .keyFile ? identityFile : nil, authentication: authentication,
                                              reverseAccess: machine?.reverseAccess)
                let credential = authentication == .password && !password.isEmpty ? password : nil
                password = ""
                if let machine { try await model.updateMachine(machine, with: config, password: credential) }
                else { try await model.connect(config, password: credential) }
                dismiss()
                if credential != nil { model.offerKeyLogin(config) }
            } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}

/// Offered once after a password login: switch this machine to a dedicated key.
struct KeyLoginSheet: View {
    let machine: ConnectionConfig
    @EnvironmentObject private var model: AppModel
    @State private var working = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: "为 \(machine.displayName) 设置免密登录？") { model.presentation = nil }.disabled(working)
            Text("以后打开应用会自动连接，不用每次输入密码。")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("在这台 Mac 上生成专用密钥 ~/.ssh/claude_mirror_ed25519", systemImage: "key")
                Label("把它的公钥加入服务器的 ~/.ssh/authorized_keys，已有内容保持不变", systemImage: "server.rack")
                Label("确认密钥能登录后才切换；以后可在服务器设置里改回密码", systemImage: "checkmark.shield")
            }.font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(WorkbenchTheme.error)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("不再询问") { model.declineKeyLogin(machine) }.disabled(working)
                Button("以后再说") { model.presentation = nil }.keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "正在设置…" : "设置免密登录") {
                    working = true; error = ""
                    Task {
                        do { try await model.setUpKeyLogin(machine); model.presentation = nil }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }.buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(working)
    }
}

/// Runs the bundled installer on the server and shows its output as it happens.
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
                    }.padding(10).textSelection(.enabled)
                }
                .frame(height: 220)
                .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
                .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            if let result {
                Label(RemoteInstaller.summary(result), systemImage: result == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(result == 0 ? WorkbenchTheme.ink : WorkbenchTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("正在安装…").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                Spacer()
                if running { Button("停止") { task?.cancel() } }
                else {
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
            lines = ["应用内缺少安装脚本，请更新到最新版本。"]; result = 1; return
        }
        running = true; result = nil; lines = []
        task = Task {
            do {
                let code = try await RemoteInstaller.run(launcher: engine.agents.launcher, config: machine, script: script) { line in
                    Task { @MainActor in lines.append(line) }
                }
                await Task.yield()
                result = code
            } catch {
                lines.append(ConnectionAdvice.explain(error.localizedDescription)); result = 1
            }
            running = false
            if result == 0 { model.recheckMachine(machine) }
        }
    }
}
#endif
