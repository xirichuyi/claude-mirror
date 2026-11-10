#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct ProjectPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var directory = ""
    @FocusState private var pathFocused: Bool
    @State private var creating = false
    @State private var folderName = ""
    @State private var busy = false
    @State private var error = ""

    private var recent: [String] {
        Array(Set(model.sessions.filter { $0.config.key == model.currentConfig?.key && !model.projectMissing($0) }.map(\.directory))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "选择项目") { dismiss() }.disabled(busy)
            Label(model.currentConfig?.displayName ?? "", systemImage: "server.rack").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
            Picker("项目", selection: $creating) {
                Text("打开项目").tag(false)
                Text("新建项目").tag(true)
            }.pickerStyle(.segmented).labelsHidden().disabled(busy)
            VStack(alignment: .leading, spacing: 8) {
                Text(creating ? "父目录" : "项目路径").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                TextField("远端目录", text: $directory).textFieldStyle(WorkbenchTextFieldStyle()).focused($pathFocused).disabled(busy)
                if creating {
                    TextField("文件夹名称", text: $folderName).textFieldStyle(WorkbenchTextFieldStyle()).disabled(busy)
                }
            }
            if !recent.isEmpty {
                Text("最近的项目").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(recent, id: \.self) { path in
                            Button { directory = path } label: {
                                HStack {
                                    Label { Text(path) } icon: { WorkbenchIcon(symbol: "folder") }.lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if directory == path { Image(systemName: "checkmark") }
                                }.padding(3).contentShape(Rectangle())
                            }.buttonStyle(SidebarNavigationStyle(selected: directory == path)).disabled(busy)
                        }
                    }
                }.frame(maxHeight: 140)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(busy ? "处理中…" : creating ? "创建并打开" : "打开项目") {
                    busy = true; error = ""
                    Task {
                        do {
                            if creating {
                                directory = try await model.createProject(in: directory, name: folderName)
                                creating = false
                                folderName = ""
                            }
                            try await model.chooseProject(directory)
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.buttonStyle(WorkbenchButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(busy || (creating && folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isConnected)
            }
        }
        .padding(28).frame(width: 460)
        .interactiveDismissDisabled(busy)
        .task { await Task.yield(); pathFocused = true }
        .onAppear { directory = model.proposedProject ?? model.active?.directory ?? model.currentConfig?.directory ?? "~" }
    }
}
#endif
