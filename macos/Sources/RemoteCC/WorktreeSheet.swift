#if canImport(SwiftUI)
import SwiftUI

struct WorktreeSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    @State private var branch = "remotecc/task-" + String(Int(Date().timeIntervalSince1970))
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "新建隔离工作区") { dismiss() }.disabled(busy)
            Text("从当前仓库的 HEAD 创建独立分支与目录，并开启新对话。原目录的未提交修改不会复制过去。").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
            TextField("新分支名", text: $branch).textFieldStyle(WorkbenchTextFieldStyle())
            Text("目录会放在仓库旁的 worktrees 文件夹中。").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WorkbenchButtonStyle()).disabled(busy)
                Button("创建并开始对话") {
                    busy = true; error = ""
                    Task {
                        defer { busy = false }
                        do { try await model.createWorktree(branch); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(busy || branch.isEmpty || !model.isConnected)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(busy)
    }
}
#endif
