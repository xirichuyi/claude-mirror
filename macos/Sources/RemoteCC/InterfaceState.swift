import SwiftUI

/// Shared wording and visual hierarchy for loading, empty and recoverable states.
struct InterfaceState: View {
    let title: String
    let detail: String
    var symbol = "tray"
    var loading = false

    var body: some View {
        VStack(spacing: 10) {
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.secondary) }
            Text(title).font(.callout.weight(.medium))
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}
