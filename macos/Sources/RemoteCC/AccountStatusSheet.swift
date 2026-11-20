#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

/// Who is signed in on the remote machine. Quota has its own sheet; session state
/// belongs to the conversation, not the account.
struct AccountStatusSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: AccountStore
    private func dismiss() { model.presentation = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "账户信息", subtitle: model.currentConfig?.displayName ?? "未选择机器") { dismiss() }
            if !model.isConnected {
                Text("连接机器后显示登录账号。").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
            } else if let status = store.status {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AccountSummary.rows(status), id: \.title) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.title).foregroundStyle(WorkbenchTheme.inkMuted).frame(width: 96, alignment: .leading)
                            Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.font(.callout)
                    }
                }
                if let error = status["accountError"]?.string {
                    Text(error).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled)
                }
            } else {
                ProgressView("正在读取…").controlSize(.small)
            }
        }
        .padding(24).frame(width: 380)
        .task { await store.refresh() }
    }
}
#endif
