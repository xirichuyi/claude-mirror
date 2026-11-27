import RemoteCCCore
import SwiftUI

struct KeyLoginSheet: View {
    let machine: ConnectionConfig
    @EnvironmentObject private var model: AppModel
    @State private var working = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: "为 \(machine.displayName) 设置免密登录？") { model.presentation = nil }.disabled(working)
            VStack(alignment: .leading, spacing: 6) {
                Label("~/.ssh/claude_mirror_ed25519", systemImage: "key")
                Label("~/.ssh/authorized_keys", systemImage: "server.rack")
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
                    working = true
                    error = ""
                    Task {
                        do {
                            try await model.setUpKeyLogin(machine)
                            model.presentation = nil
                        } catch { self.error = error.localizedDescription }
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
