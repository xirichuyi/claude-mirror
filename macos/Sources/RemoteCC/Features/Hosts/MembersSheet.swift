import RemoteCCCore
import SwiftUI

/// Accounts on a shared server: each member logs in with their own key and Claude account.
struct MembersSheet: View {
    let machine: ConnectionConfig
    @EnvironmentObject private var model: AppModel
    @State private var members: [RemoteMember] = []
    @State private var loading = true
    @State private var busy = false
    @State private var name = ""
    @State private var key = ""
    @State private var removing: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeading(title: "成员 · \(machine.displayName)") { model.presentation = nil }
            VStack(alignment: .leading, spacing: 0) {
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if members.isEmpty {
                    Text("无成员").foregroundStyle(WorkbenchTheme.inkMuted).padding(.vertical, 12)
                }
                ForEach(members) { member in
                    row(member)
                    Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
                }
            }
            HStack(spacing: 8) {
                TextField("账号", text: $name).textFieldStyle(WorkbenchTextFieldStyle()).frame(width: 120)
                TextField("公钥 ssh-ed25519 …", text: $key).textFieldStyle(WorkbenchTextFieldStyle())
                    .onSubmit { add() }
                Button { add() } label: { WorkbenchIcon(symbol: "plus") }
                    .buttonStyle(WorkbenchIconButtonStyle()).help("添加成员").accessibilityLabel("添加成员")
                    .disabled(name.isEmpty || key.isEmpty)
            }.disabled(busy)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(WorkbenchTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { model.presentation = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(busy)
        .task { await reload() }
    }

    private func row(_ member: RemoteMember) -> some View {
        HStack(spacing: 10) {
            WorkbenchIcon(symbol: "person").foregroundStyle(WorkbenchTheme.inkMuted).frame(width: 24, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.name).font(WorkbenchMetrics.ui)
                if !member.fingerprint.isEmpty {
                    Text(member.fingerprint).font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if removing == member.name {
                Text("删除账号和全部文件").font(WorkbenchMetrics.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                Button("取消") { removing = nil }.buttonStyle(QuietButtonStyle())
                Button("删除") { remove(member.name) }.buttonStyle(QuietButtonStyle()).foregroundStyle(WorkbenchTheme.error)
            } else {
                Button { removing = member.name } label: { WorkbenchIcon(symbol: "trash") }
                    .buttonStyle(WorkbenchIconButtonStyle()).help("删除成员").accessibilityLabel("删除 " + member.name)
            }
        }.frame(minHeight: 40).disabled(busy)
    }

    private func reload() async {
        loading = members.isEmpty
        defer { loading = false }
        guard let engine = model.engine, let script = engine.agents.resources.installScript else { return }
        do { members = try await RemoteMembers.list(launcher: engine.agents.launcher, config: machine, script: script) }
        catch { self.error = error.localizedDescription }
    }

    private func add() {
        let account = name.trimmingCharacters(in: .whitespaces)
        let publicKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !publicKey.isEmpty else { return }
        perform(["--add-user", account, "--key", publicKey]) { name = ""; key = "" }
    }

    private func remove(_ account: String) {
        perform(["--remove-user", account]) { removing = nil }
    }

    private func perform(_ arguments: [String], done: @escaping () -> Void) {
        guard let engine = model.engine, let script = engine.agents.resources.installScript else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await RemoteMembers.run(launcher: engine.agents.launcher, config: machine, script: script, arguments: arguments)
                done()
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}
