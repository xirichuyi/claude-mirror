import SwiftUI

struct WorkbenchConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let actionTitle: String
    var cancelTitle = "取消"
    var destructive = false
    let action: () -> Void
}

struct WorkbenchRename: Identifiable {
    let id = UUID()
    let title: String
    let initial: String
    var returnToSettings = false
    let save: (String) -> Void
}

struct ConfirmationSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: WorkbenchConfirmation
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: request.title) { model.presentation = nil }
            Text(request.detail).foregroundStyle(WorkbenchTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Spacer()
                Button(request.cancelTitle) { model.presentation = nil }.keyboardShortcut(.defaultAction)
                Button(request.actionTitle, role: request.destructive ? .destructive : nil) {
                    model.presentation = nil
                    request.action()
                }.buttonStyle(WorkbenchButtonStyle(prominent: true))
            }.padding(.top, 8)
        }.padding(24).frame(width: 480)
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: WorkbenchRename
    @State private var name = ""
    @FocusState private var focused: Bool
    private func close() { model.presentation = request.returnToSettings ? .settings : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: request.title, close: close)
            TextField("名称", text: $name).focused($focused)
            HStack {
                Spacer()
                Button("取消", action: close)
                Button("保存") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    close(); request.save(value)
                }.buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440)
            .defaultFocus($focused, true)
            .task { name = request.initial; await Task.yield(); focused = true }
    }
}
