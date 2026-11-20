import RemoteCCCore
import SwiftUI

struct ProjectPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var directory = ""
    @State private var creating = false
    @State private var folderName = ""
    @State private var busy = false
    @State private var loading = false
    @State private var error = ""
    @State private var listing: DirectoryListing?
    @State private var requestedPath = "~"
    @State private var requestID = 0

    @State private var folders: [FileEntry] = []
    @State private var cachedListings: [String: DirectoryListing] = [:]

    private var canOpen: Bool {
        !busy && !loading && model.isConnected && listing?.path == directory

    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeading(title: "选择目录 · " + (model.currentConfig?.displayName ?? "")) { dismiss() }.disabled(busy)
            navigation
            directoryList
            if creating {
                HStack {
                    TextField("文件夹名称", text: $folderName)
                        .textFieldStyle(WorkbenchTextFieldStyle()).onSubmit { createFolder() }
                    Button("取消") { creating = false }.buttonStyle(QuietButtonStyle())
                    Button("创建") { createFolder() }.buttonStyle(QuietButtonStyle())
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.disabled(busy)
            }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(WorkbenchTheme.error).textSelection(.enabled)
            }
            HStack {
                Button {
                    creating.toggle()
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }.buttonStyle(QuietButtonStyle()).disabled(!canOpen)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                    .buttonStyle(QuietButtonStyle())
                Button(busy ? "处理中…" : "打开") { openProject() }
                    .buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(!canOpen)
            }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(busy)
        .onAppear {
            navigate(model.proposedProject ?? model.active?.directory ?? model.currentConfig?.directory ?? "~")
        }
        .task(id: requestID) { await loadDirectory() }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button {
                if let listing { navigate(listing.parent) }
            } label: {
                WorkbenchIcon(symbol: "arrow.up")
            }.buttonStyle(WorkbenchIconButtonStyle()).help("上一级")
                .disabled(busy || loading || listing == nil || listing?.parent == listing?.path)
            Button {
                navigate("~")
            } label: {
                WorkbenchIcon(symbol: "house")
            }
            .buttonStyle(WorkbenchIconButtonStyle()).help("远端主目录").disabled(busy)
            TextField("远端目录路径", text: $directory)
                .textFieldStyle(WorkbenchTextFieldStyle()).disabled(busy)
                .onSubmit { navigate(directory) }

        }
    }

    private var directoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(folders) { folder in
                    Button {
                        navigate(folder.path)
                    } label: {
                        HStack(spacing: 8) {
                            WorkbenchIcon(symbol: "folder")
                            Text(folder.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            WorkbenchIcon(symbol: "chevron.right").scaleEffect(0.7)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                    }.buttonStyle(QuietButtonStyle(height: 30)).help(folder.path).disabled(busy || loading)
                }
                if listing?.truncated == true {
                    Text("目录较多，未全部显示；可输入完整路径前往。")
                        .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(8)
                }
            }.padding(6)
        }
        .id(listing?.path ?? "")
        .frame(height: 260)
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if loading {
                ProgressView().controlSize(.small)
            } else if listing != nil && folders.isEmpty {
                Text("没有子目录").font(.callout).foregroundStyle(WorkbenchTheme.inkMuted)
            }
        }
    }

    private func dismiss() { model.presentation = nil }

    private func navigate(_ path: String) {
        guard !busy, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        directory = path
        requestedPath = path
        error = ""
        if let cached = cachedListings[path] {
            apply(cached)
            loading = false
        } else {
            loading = true
        }
        requestID += 1
    }

    private func loadDirectory() async {
        let request = requestID
        let path = requestedPath
        guard let engine = model.engine, let config = model.currentConfig, model.isConnected else {
            loading = false
            error = "请先连接服务器"
            return
        }
        do {
            let result = try await engine.files.list(config, path, hidden: false)
            // A late response must not replace a newer navigation or another host's directory.
            guard !Task.isCancelled, request == requestID, model.currentConfig?.key == config.key else { return }
            apply(result)
            if directory == path { directory = result.path }
            requestedPath = result.path
            loading = false
        } catch {
            guard !Task.isCancelled, request == requestID else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func apply(_ result: DirectoryListing) {
        cachedListings[result.path] = result
        if listing == result { return }
        listing = result
        folders = result.entries.filter { $0.directory && $0.broken != true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func createFolder() {
        guard canOpen, !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task {
            do {
                let path = try await model.createProject(in: directory, name: folderName)
                cachedListings.removeValue(forKey: directory)
                busy = false
                creating = false
                folderName = ""
                navigate(path)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    private func openProject() {
        guard canOpen else { return }
        busy = true
        error = ""
        Task {
            do {
                try await model.chooseProject(directory)
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
