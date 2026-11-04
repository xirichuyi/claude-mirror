import SwiftUI
import RemoteCCCore

struct QuotaOverview: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: AccountStore
    private var report: JSON? { store.status?["quota"] }
    private var failure: String? { store.failure }
    private var refreshing: Bool { store.refreshing }
    private var windows: [JSON] { report?["windows"]?.array ?? [] }
    private func refresh() async { await store.refresh() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("账户额度", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(refreshing || !model.isConnected || model.currentConfig == nil)
                .help("刷新远端账户额度")
                .accessibilityLabel("刷新账户额度")
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(failure)
            } else if let report, report["available"]?.isTruthy == true {
                ForEach(windows, id: \.self) { window in
                    if let used = window["used"]?.double {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window["id"]?.string == "five_hour" ? "五小时已用" : "本周已用")
                                Spacer()
                                Text("\(used, specifier: "%.0f")%")
                                    .monospacedDigit()
                            }.font(.caption)
                            ProgressView(value: used, total: 100)
                                .tint(used >= 95 ? .orange : WorkbenchTheme.accent)
                                .accessibilityLabel(window["id"]?.string == "five_hour" ? "五小时已用" : "本周已用")
                                .accessibilityValue("\(Int(used))%")
                            if let reset = QuotaReset.date(window["resetsAt"]?.string) {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(QuotaReset.countdown(until: reset, now: context.date))
                                        Text(QuotaReset.localTime(reset))
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("重置时间暂不可用").font(.caption2).foregroundStyle(.secondary)
                            }

                        }
                        .help(window["resetsAt"]?.string.map { "重置时间：" + $0 } ?? "")
                    }
                }
                DisclosureGroup(report["blocked"]?.isTruthy == true ? "已触发额度保护" : "额度保护 · 95% 停止线") {
                    Text("同一远端登录已用达到 90% 后限制并行任务；检测到任一周期已用 95% 时停止。用量反馈有延迟，无法保证精确保留 5%。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Text(refreshing ? "正在读取…" : model.isConnected ? "正在读取账户额度…" : "连接后显示远端额度")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }
}

struct AccountUsageSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "订阅用量", subtitle: "五小时与本周 · 已用额度") { dismiss() }
            QuotaOverview(store: model.accountStore)
        }.padding(24).frame(width: 380)
            .task { await model.accountStore.refresh() }
    }
}
