#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct UsageReportView: View {
    let report: UsageReport
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("订阅用量", systemImage: "chart.bar").font(.headline)
                Spacer()
                Text("查询时快照").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            }
            ForEach(Array(report.windows.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(window.percent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                            .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(WorkbenchTheme.border.opacity(0.5))
                            Capsule().fill(window.percent >= 90 ? WorkbenchTheme.ink : WorkbenchTheme.sage)
                                .frame(width: geometry.size.width * window.percent / 100)
                        }
                    }.frame(height: 7)
                        .accessibilityLabel(window.title).accessibilityValue("已使用 \(Int(window.percent))%")
                    if let reset = window.reset {
                        Text("重置于 " + reset).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !report.activity.isEmpty {
                HStack(spacing: 20) {
                    ForEach(Array(report.activity.enumerated()), id: \.offset) { _, activity in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(activity.title).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                            Text(activity.requests + " 次请求").font(.callout.weight(.medium)).monospacedDigit()
                            Text(activity.sessions + " 个会话").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("使用分析仅统计这台服务器").font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted)
            }
            DisclosureGroup("详细报告", isExpanded: $expanded) {
                Text(report.raw).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }.font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
        }
        .padding(22).frame(maxWidth: 520, alignment: .leading)
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WorkbenchTheme.border.opacity(0.6)))
    }
}
#endif
