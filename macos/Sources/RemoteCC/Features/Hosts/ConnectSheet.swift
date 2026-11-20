import AppKit
import RemoteCCCore
import SwiftUI

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
        VStack(alignment: .leading, spacing: 12) {
            SheetHeading(title: machine == nil ? "添加服务器" : "编辑服务器") { dismiss() }
                .disabled(connecting)
            VStack(alignment: .leading, spacing: 12) {
                connectionField("服务器地址", text: $host, prompt: "user@hostname")
                WorkbenchSelect(
                    title: "登录方式", selection: $authentication,
                    options: [
                        WorkbenchOption(.password, "密码"), WorkbenchOption(.keyFile, "私钥文件"),
                        WorkbenchOption(.automatic, "本机 SSH 配置"),
                    ]
                ).help(authenticationNote)
                if authentication == .password {
                    WorkbenchFormRow("密码") {
                        SecureField("服务器登录密码", text: $password)
                            .textFieldStyle(WorkbenchTextFieldStyle())
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
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionField("显示名称", text: $name, prompt: "可选")
                        connectionField("用户名", text: $username, prompt: "可选")
                        connectionField("端口", text: $port, prompt: "22")
                    }.padding(.top, 8)
                } label: {
                    Text("高级选项").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
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
                    Text("正在连接…").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WorkbenchButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(connecting)
                Button(connecting ? "连接中…" : machine == nil ? "连接" : "保存并重连") { connect() }
                    .buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(
                        connecting || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (authentication == .keyFile && identityFile.isEmpty)
                            || (authentication == .password && password.isEmpty && machine == nil))
            }
        }
        .font(WorkbenchMetrics.ui).padding(WorkbenchMetrics.dialogPadding).frame(width: 440)
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
        .task {
            await Task.yield()
            focusedField = "服务器地址"
        }
        .onChange(of: authentication) { _, _ in password = "" }
        .onDisappear { password = "" }
    }

    private func connectionField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        WorkbenchFormRow(label) {
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.plain).focused(
                $focusedField, equals: label
            )
            .modifier(WorkbenchFieldSurface(focused: focusedField == label))
        }
    }

    private func connect() {
        connecting = true
        error = ""
        Task {
            do {
                let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard user.isEmpty || !address.contains("@") else { throw RemoteError("地址里已经写了用户名，请清空“高级选项”里的用户名") }
                guard user.isEmpty || (!user.contains("@") && !user.contains(":")) else {
                    throw RemoteError("用户名不能包含 @ 或冒号")
                }
                let destination = user.isEmpty ? address : user + "@" + address
                // Reverse access is turned on from the machine's settings, never while adding it.
                let config = ConnectionConfig(
                    host: destination, port: try ConnectionConfig.parsePort(port), directory: "~",
                    name: name, identityFile: authentication == .keyFile ? identityFile : nil,
                    authentication: authentication,
                    reverseAccess: machine?.reverseAccess)
                let credential = authentication == .password && !password.isEmpty ? password : nil
                password = ""
                if let machine {
                    try await model.updateMachine(machine, with: config, password: credential)
                } else {
                    try await model.connect(config, password: credential)
                }
                dismiss()
                if credential != nil { model.offerKeyLogin(config) }
            } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}

/// Offered once after a password login: switch this machine to a dedicated key.
