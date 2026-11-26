#if canImport(SwiftUI)
import SwiftUI
import RemoteCCCore

struct RewindSheet: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.presentation = nil }
    let sessionId: String
    let checkpoint: String
    @State private var preview: JSON?
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: "回退本轮之前的文件") { dismiss() }.disabled(busy)
            Text("本轮新建的文件会被删除；聊天记录不变，Bash 和子代理的修改可能不会恢复。").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
            if busy { ProgressView("正在处理…") }
            if let preview {
                ScrollView { VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview["filesChanged"]?.array?.compactMap(\.string) ?? [], id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240)
                if preview["canRewind"]?.bool != true { Text(preview["error"]?.string ?? "无可回退的文件").foregroundStyle(WorkbenchTheme.inkMuted) }
            }
            if !error.isEmpty { Text(error).foregroundStyle(WorkbenchTheme.error).font(.caption).textSelection(.enabled) }
            HStack {
                Button("重新预览") { perform(apply: false) }.disabled(busy)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WorkbenchButtonStyle()).disabled(busy)
                Button("确认回退这些文件", role: .destructive) { perform(apply: true) }
                    .disabled(busy || preview?["canRewind"]?.bool != true || preview?["token"]?.string == nil)
            }
        }.padding(24).frame(width: 580).interactiveDismissDisabled(busy)
            .task { perform(apply: false) }
    }
    private func perform(apply: Bool) {
        guard let engine = model.engine else { return }
        let token = apply ? preview?["token"]?.string : nil
        busy = true; error = ""
        Task {
            defer { busy = false }
            do {
                let result = try await engine.rewindFiles(sessionId, checkpoint: checkpoint, token: token)
                if apply {
                    guard result["canRewind"]?.bool == true else { error = result["error"]?.string ?? "回退未完成"; preview = nil; return }
                    model.show((result["skippedLinks"]?.int ?? 0) > 0 ? "已回退，部分路径已跳过" : "已回退")
                    if model.activeId == sessionId { await model.activeWorkspace?.reload(force: true) }
                    dismiss()
                } else { preview = result }
            } catch { self.error = error.localizedDescription; preview = nil }
        }
    }
}
#endif
