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
                Image(systemName: "arrow.clockwise").opacity(syncing ? 0 : 1)
                if syncing { ProgressView().controlSize(.mini) }
            }.frame(width: 16, height: 16)
        }
        .buttonStyle(QuietButtonStyle())
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
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var name = ""
    @State private var username = ""
    @State private var identityFile = ""
    @State private var password = ""
    @State private var authentication = SSHAuthentication.automatic
    @State private var reverseAccess = false
    @State private var error = ""
    @State private var connecting = false
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("添加机器").font(.title2.weight(.semibold))
                Text("通过 SSH 连接远端 Claude Code。")
                    .font(.body).foregroundStyle(WorkbenchTheme.inkMuted)
            }
            VStack(alignment: .leading, spacing: 16) {
                connectionField("主机名称", text: $name, prompt: "例如：开发服务器（可选）")
                connectionField("SSH 主机", text: $host, prompt: "IP、域名、SSH 别名或 user@host")
                HStack {
                    connectionField("用户名", text: $username, prompt: "留空使用 SSH 配置")
                    connectionField("端口", text: $port, prompt: "默认使用 SSH 配置")
                }
                Picker("认证方式", selection: $authentication) {
                    Text("SSH 配置 / Agent").tag(SSHAuthentication.automatic)
                    Text("密码").tag(SSHAuthentication.password)
                    Text("私钥文件").tag(SSHAuthentication.keyFile)
                }
                if authentication == .password {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("密码").font(.callout.weight(.medium))
                        SecureField("服务器密码", text: $password)
                            .textFieldStyle(.plain).font(.body).padding(12)
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
                            if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
                        }
                    }
                }
            }
            Toggle("允许此服务器反向连接本机", isOn: $reverseAccess)
                .font(.callout)
                .help("复用本应用的 SSH 连接，让服务器通过私有 socket 连到本机的远程登录服务。服务器会获得一把只能经此通道使用的专用密钥，关闭后立即撤销；开启期间服务器上的程序能以你的身份登录这台 Mac。")
            Text(authentication == .password ? "密码仅用于本次连接，不会保存。" : authentication == .keyFile ? "使用所选私钥认证，不会上传私钥。" : "使用本机 SSH 配置与 SSH Agent 认证。")
                .font(.subheadline).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(WorkbenchTheme.error).textSelection(.enabled)
            }
            HStack {
                if connecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WorkbenchButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(connecting)
                Button(connecting ? "连接并同步中…" : "连接机器") { connect() }
                    .buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(connecting || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (authentication == .keyFile && identityFile.isEmpty))
            }
        }
        .padding(28).frame(width: 460)
        .interactiveDismissDisabled(connecting)
        .task { await Task.yield(); focusedField = "SSH 主机" }
        .onChange(of: authentication) { _, _ in password = "" }
        .onDisappear { password = "" }
    }

    private func connectionField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout.weight(.medium))
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.plain).focused($focusedField, equals: label)
                .font(.body).padding(12)
                .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.border))
        }
    }

    private func connect() {
        connecting = true; error = ""
        Task {
            do {
                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard user.isEmpty || !host.contains("@") else { throw RemoteError("主机地址已包含用户名，请清空单独的用户名字段") }
                guard user.isEmpty || (!user.contains("@") && !user.contains(":")) else { throw RemoteError("用户名不能包含 @ 或冒号") }
                let destination = user.isEmpty ? host : user + "@" + host.trimmingCharacters(in: .whitespacesAndNewlines)
                let config = ConnectionConfig(host: destination, port: try ConnectionConfig.parsePort(port), directory: "~",
                                              name: name, identityFile: authentication == .keyFile ? identityFile : nil, authentication: authentication,
                                              reverseAccess: reverseAccess ? true : nil)
                let credential = authentication == .password && !password.isEmpty ? password : nil
                password = ""
                try await model.connect(config, password: credential)
                dismiss()
            } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}
#endif
