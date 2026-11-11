import SwiftUI
import RemoteCCCore

/// Keep account identity and subscription usage visible outside conversation menus.
struct AccountQuotaView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: AccountStore

    private var email: String { store.status?["account"]?["email"]?.string ?? "账户" }
    private var windows: [JSON] { store.status?["quota"]?["windows"]?.array ?? [] }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.presentation = .account } label: {
                HStack(spacing: 5) {
                    WorkbenchIcon(symbol: "person.crop.circle")
                    // Truncate the string, not a flexible frame: a flexible frame leaves a gap around short names.
                    Text(email.count > 26 ? String(email.prefix(12)) + "…" + String(email.suffix(12)) : email).lineLimit(1).fixedSize()
                }
            }
            .help(email).accessibilityLabel("账户信息")
            Button { model.presentation = .accountUsage } label: {
                HStack(spacing: 5) {
                    WorkbenchIcon(symbol: "chart.bar")
                    if !model.isConnected {
                        Text("用量离线")
                    } else if store.failure != nil {
                        Text("用量暂不可用")
                    } else if windows.contains(where: { $0["used"]?.double != nil }) {
                        Text("5h \(usage("five_hour")) · 本周 \(usage("seven_day"))").monospacedDigit()
                    } else {
                        Text(store.refreshing ? "用量读取中…" : "用量未报告")
                    }
                }.fixedSize()
            }
            .help(store.failure ?? "查看订阅已用额度与重置时间")
            .accessibilityLabel("订阅用量")
        }
        .font(.system(size: 11))
        .buttonStyle(QuietButtonStyle())
    }

    private func usage(_ id: String) -> String {
        guard let used = windows.first(where: { $0["id"]?.string == id })?["used"]?.double,
              used.isFinite else { return "—" }
        return String(format: "%.0f%%", used)
    }
}
