#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

/// The quota belongs to the remote login, not to an individual conversation's cost.
struct AccountQuotaView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: AccountStore
    @State private var showPopover = false
    @State private var showingUsage = false
    private var account: JSON? { store.status }
    private var report: JSON? { store.status?["quota"] }
    private var failure: String? { store.failure }
    private var refreshing: Bool { store.refreshing }

    private var windows: [JSON] { (report?["windows"]?.array ?? []).filter { ["five_hour", "seven_day"].contains($0["id"]?.string ?? "") } }

    var body: some View {
        Button { showingUsage = false; showPopover.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle").font(.system(size: 20))
                Text(account?["account"]?["email"]?.string ?? "账号")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("账号、订阅与用量")
        .accessibilityLabel("账号与用量")
        .padding(.horizontal, 6).padding(.bottom, 6)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            accountPopover
                .presentationBackground {
                    FrostedBackground(material: .popover)
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.45)) }
                        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
                }
                .task { await refresh() }
        }
    }

    private var accountPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showingUsage {
                Button { showingUsage = false } label: {
                    Label("账号", systemImage: "chevron.left").font(.callout)
                }.buttonStyle(.plain).padding(10)
                QuotaOverview(store: store).padding(12)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(WorkbenchTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account?["account"]?["email"]?.string ?? "远端账号")
                            .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            .help(account?["account"]?["email"]?.string ?? "")
                        Text(account?["account"]?["subscriptionType"]?.string ?? "订阅信息未报告")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12)
                Divider().padding(.horizontal, 8)
                accountAction("用量", icon: "chart.bar", detail: usageSummary, chevron: true) { showingUsage = true }
                accountAction("账号详情", icon: "person.crop.circle", chevron: true) {
                    showPopover = false
                    model.presentation = .account
                }
                accountAction("设置", icon: "gearshape") {
                    showPopover = false
                    model.showSettings = true
                }
                if model.isConnected {
                    Divider().padding(.horizontal, 8)
                    accountAction("断开服务器", icon: "rectangle.portrait.and.arrow.right", detail: model.currentConfig?.displayName) {
                        showPopover = false
                        model.disconnect()
                    }
                }
            }
        }
        .padding(6).frame(width: 300)
        .foregroundStyle(WorkbenchTheme.ink)
        .tint(WorkbenchTheme.accent)
    }

    private var usageSummary: String? {
        guard failure == nil, let week = windows.first(where: { $0["id"]?.string == "seven_day" }),
              let used = week["used"]?.double else { return nil }
        return String(format: "本周已用 %.0f%%", used)
    }

    private func accountAction(_ title: String, icon: String, detail: String? = nil, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if chevron { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
            }.font(.callout).padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(AccountMenuRowStyle())
    }

    private func refresh() async { await store.refresh() }

}
private struct AccountMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccountMenuRow(configuration: configuration)
    }
    private struct AccountMenuRow: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(WorkbenchTheme.ink.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovered = $0 }
        }
    }
}
#endif
