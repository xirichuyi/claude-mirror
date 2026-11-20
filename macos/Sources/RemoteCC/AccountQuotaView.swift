import SwiftUI
import RemoteCCCore

/// Keep account identity and subscription usage visible outside conversation menus.
struct AccountQuotaView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: AccountStore

    private var initials: String {
        guard let email = store.status?["account"]?["email"]?.string,
              let name = email.split(separator: "@").first else { return "" }
        return String(name.prefix(2)).uppercased()
    }
    private var windows: [JSON] { store.status?["quota"]?["windows"]?.array ?? [] }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.presentation = .account } label: {
                ZStack {
                    Circle().fill(WorkbenchTheme.accent)
                    if initials.isEmpty {
                        WorkbenchIcon(symbol: "person.crop.circle").frame(width: 14, height: 14)
                    } else {
                        Text(initials).font(.system(size: 9, weight: .semibold))
                    }
                }.foregroundStyle(Color.white).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("账户信息").accessibilityLabel("账户信息")
            Button { model.presentation = .accountUsage } label: {
                HStack(spacing: 5) {
                    WorkbenchIcon(symbol: "chart.bar")
                    if !model.isConnected {
                        Text("用量离线")
                    } else if store.failure != nil {
                        Text("用量暂不可用")
                    } else if windows.contains(where: { $0["used"]?.double != nil }) {
                        Text("5h \(usage("five_hour")) · 7d \(usage("seven_day"))").monospacedDigit()
                    } else {
                        Text(store.refreshing ? "用量读取中…" : "用量未报告")
                    }
                }.fixedSize(horizontal: true, vertical: false)
                    .frame(width: 148, alignment: .leading)
            }
            .help(quotaHelp)
            .accessibilityLabel("订阅用量")
        }
        .font(.system(size: 11))
        .buttonStyle(QuietButtonStyle())
    }

    private var quotaHelp: String {
        if !model.isConnected { return "用量离线，连接服务器后刷新" }
        if let failure = store.failure { return "用量暂不可用：" + failure }
        if windows.contains(where: { $0["used"]?.double != nil }) {
            return "5 小时已用 \(usage("five_hour")) / 7 天已用 \(usage("seven_day"))\n点击查看详细用量和重置时间"
        }
        return store.refreshing ? "正在读取订阅用量" : "尚未获取订阅用量，点击查看详情"
    }

    private func usage(_ id: String) -> String {
        guard let used = windows.first(where: { $0["id"]?.string == id })?["used"]?.double,
              used.isFinite else { return "—" }
        return String(format: "%.0f%%", used)
    }
}
