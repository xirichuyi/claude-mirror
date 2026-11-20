import AppKit
import SwiftUI

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
                WorkbenchIcon(symbol: "arrow.clockwise").opacity(syncing ? 0 : 1)
                if syncing { ProgressView().controlSize(.mini) }
            }.frame(width: 16, height: 16)
        }
        .buttonStyle(WorkbenchIconButtonStyle())
        .disabled(!model.isConnected || syncing)
        .accessibilityLabel(syncing ? "正在同步会话" : "同步会话")
        .help("同步会话 · " + (model.connectionState.error.isEmpty ? model.historyStatus : model.connectionState.error))
    }
}
