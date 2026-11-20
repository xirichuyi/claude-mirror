import Foundation
import Observation

@Observable public final class EditorTab: Identifiable {
    public let id: String
    public var path: String
    public let isDiff: Bool
    public var preview: FilePreview?
    public var isValidating = false
    var loadID = UUID()
    var loadTask: Task<FilePreview, Error>?
    public var diffText: String?
    public var error: String?
    /// Non-nil while editing; a difference from `preview.text` means unsaved work.
    public var draft: String?
    public var conflict = false
    public var line: Int?
    public var showSource = false
    public var notice: String?
    init(id: String, path: String, isDiff: Bool, line: Int? = nil) { self.id = id; self.path = path; self.isDiff = isDiff; self.line = line }
    public var isDirty: Bool { draft != nil && draft != preview?.text }
    public var title: String { (path as NSString).lastPathComponent + (isDiff ? " · 变更" : "") }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

public struct TreeRow: Identifiable, Equatable {
    public var entry: FileEntry
    public var depth: Int
    public var expanded: Bool
    public var gitCode: String?
    public var touched: Bool
    public var loading = false
    public var id: String { entry.path }
}

/// The file panel and editor tabs for one conversation; views only render this.
@MainActor
@Observable public final class Workspace {
    public private(set) var root: String?
    public private(set) var rows: [TreeRow] = []
    public private(set) var error: String?
    public private(set) var footer = ""
    public private(set) var gitStatus: GitStatus?
    public private(set) var watchFailed = false
    public private(set) var tabs: [EditorTab] = []
    public var activeTabId: String?
    public var showHidden = true { didSet { if showHidden != oldValue { Task { await reload(force: true) } } } }
    public var touchedFiles: () -> Set<String> = { [] }
    public var onChange: (() -> Void)?

    /// Use this workspace's host even if the user switches conversations during transfer.
    public func downloadPreview(_ path: String, to destination: URL) async throws {
        try await files.download(config, path, to: destination)
    }

    private let files: RemoteFiles
    private let agents: AgentClient
    private let config: ConnectionConfig
    private var directories: [String: DirectoryListing] = [:]
    private var expanded = Set<String>()
    private var directoryLoads: [String: UUID] = [:]
    private var git: [String: String] = [:]
    private var generation = 0

    public init(files: RemoteFiles, agents: AgentClient, config: ConnectionConfig) {
        self.files = files; self.agents = agents; self.config = config
    }

    public var activeTab: EditorTab? { tabs.first { $0.id == activeTabId } }
    public var hasUnsavedEdits: Bool { tabs.contains(where: \.isDirty) }
    private func changed() { onChange?() }

    public func browse(_ folder: String, force: Bool = false) async {
        directoryLoads.removeAll()
        generation += 1
        let current = generation
        error = nil; footer = "读取中…"; changed()
        do {
            let listing = try await files.list(config, folder, hidden: showHidden, force: force)
            guard current == generation else { return }
            if root != listing.path { expanded = []; directories = [:]; root = listing.path }
            directories[listing.path] = listing
            rebuild() // Show the root immediately, before refreshing expanded children.
            let files = self.files, config = self.config, hidden = showHidden
            var pending = Array(expanded).makeIterator()
            var failed = false
            await withTaskGroup(of: (String, DirectoryListing?).self) { group in
                func enqueue(_ directory: String) {
                    group.addTask { (directory, try? await files.list(config, directory, hidden: hidden, force: force)) }
                }
                for _ in 0..<4 { if let directory = pending.next() { enqueue(directory) } }
                for await (directory, listing) in group {
                    guard current == generation else { group.cancelAll(); continue }
                    if let listing { directories[directory] = listing } else { failed = true }
                    if let directory = pending.next() { enqueue(directory) }
                }
            }
            guard current == generation else { return }
            rebuild()
            if failed { footer += " · 部分目录刷新失败，保留上次内容"; changed() }
            await syncWatches()
            await refreshGit()
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
            footer = rows.isEmpty ? "读取失败" : "刷新失败 · 显示上次加载的目录"
            changed()
        }
    }

    public func reload(force: Bool = false) async {
        if let root { await browse(root, force: force) } else { await browse(config.directory, force: force) }
    }
    public func goToParent() async { if let root, let parent = directories[root]?.parent { await browse(parent) } }

    public func rebuild() {
        guard let root else { return }
        let touched = touchedFiles()
        var result: [TreeRow] = []
        func walk(_ directory: String, _ depth: Int) {
            for entry in directories[directory]?.entries ?? [] {
                let open = expanded.contains(entry.path)
                result.append(TreeRow(entry: entry, depth: depth, expanded: open, gitCode: git[entry.path], touched: touched.contains(entry.path), loading: directoryLoads[entry.path] != nil))
                if entry.directory, open, directories[entry.path] != nil { walk(entry.path, depth + 1) }
            }
        }
        walk(root, 0)
        if rows != result { rows = result }
        let listing = directories[root]
        footer = "\(listing?.entries.count ?? 0) 项" + (listing?.truncated == true ? " · 仅显示前 5000 项" : "") + (watchFailed ? " · 未能实时监听，回复结束后刷新" : "")
        changed()
    }

    public func toggle(_ directory: String) async {
        if expanded.remove(directory) != nil {
            directoryLoads[directory] = nil
            rebuild()
            await syncWatches()
            return
        }
        expanded.insert(directory)
        let request = UUID()
        let version = generation
        directoryLoads[directory] = request
        error = nil
        rebuild() // Chevron and cached children respond before the network round trip.
        do {
            let listing = try await files.list(config, directory, hidden: showHidden)
            guard generation == version, directoryLoads[directory] == request else { return }
            directories[directory] = listing
        } catch {
            guard generation == version, directoryLoads[directory] == request else { return }
            expanded.remove(directory)
            self.error = error.localizedDescription
        }
        directoryLoads[directory] = nil
        rebuild()
        await syncWatches()
    }

    public func collapseAll() async {
        directoryLoads.removeAll()
        expanded.removeAll()
        rebuild()
        await syncWatches()
    }

    /// Reveal the selected file without changing the browser root or collapsing other folders.
    public func revealActiveFile() async -> String? {
        guard let root, let path = activeTab?.path else { return nil }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let version = generation
        let components = path.dropFirst(prefix.count).split(separator: "/").dropLast()
        var directory = root == "/" ? "" : root
        for component in components {
            directory += "/" + component
            guard !Task.isCancelled, generation == version, activeTab?.path == path else { return nil }
            if !expanded.contains(directory) {
                do {
                    let listing = try await files.list(config, directory, hidden: showHidden)
                    guard !Task.isCancelled, generation == version, activeTab?.path == path else { return nil }
                    directories[directory] = listing
                    expanded.insert(directory)
                    rebuild()
                } catch { return nil }
            }
        }
        await syncWatches()
        guard !Task.isCancelled, generation == version, activeTab?.path == path else { return nil }
        return path
    }

    /// Only what is on screen is watched: the root, expanded folders and folders of open files.
    public func syncWatches() async {
        guard let root else { return }
        let open = tabs.filter { !$0.isDiff && $0.path.hasPrefix("/") }.map(\.directory)
        let wanted = Array(Set([root] + expanded + open))
        do {
            let result = try await agents.call(config, "watchDirectories", ["directories": .array(wanted.map(JSON.string))])
            let failed = !(result["failed"]?.array ?? []).isEmpty
            if failed != watchFailed { watchFailed = failed; rebuild() }
        } catch { watchFailed = true }
    }

    public func refreshGit() async {
        guard let status = try? await files.run(config, "gitStatus", timeout: 25).decode(GitStatus.self) else { return }
        gitStatus = status
        git = [:]
        for file in status.files {
            git[file.path] = file.code
            // A folder shows that something inside it changed.
            var parent = (file.path as NSString).deletingLastPathComponent
            while parent.count > (status.root ?? "").count {
                if git[parent] == nil { git[parent] = "M" }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        rebuild()
    }

    /// A push from the server. Clean tabs follow it; tabs with unsaved edits are flagged instead.
    public func filesChanged(_ changedDirectories: [String]) async {
        files.invalidate(config)
        for directory in changedDirectories where directories[directory] != nil {
            if let listing = try? await files.list(config, directory, hidden: showHidden, force: true) { directories[directory] = listing }
        }
        rebuild()
        await refreshGit()
        for tab in tabs where changedDirectories.contains(tab.directory) {
            if tab.isDiff { tab.diffText = (try? await files.run(config, "gitFileDiff", ["path": .string(tab.path)]))?["text"]?.string; continue }
            do {
                let latest = try await files.preview(config, tab.path)
                guard latest.version != tab.preview?.version else { continue }
                if tab.isDirty { tab.conflict = true }
                else { tab.preview = latest; tab.draft = nil; tab.conflict = false; tab.line = nil }
                tab.error = nil
            } catch { tab.error = error.localizedDescription }
        }
        changed()
    }

    // MARK: Tabs

    @discardableResult
    private func addTab(_ id: String, path: String, isDiff: Bool, line: Int?) -> EditorTab {
        if let tab = tabs.first(where: { $0.id == id }) {
            tab.line = line ?? tab.line
            activeTabId = id; changed()
            return tab
        }
        // Images and PDFs hold their bytes in memory, so old clean tabs are dropped.
        while tabs.count >= 12, let old = tabs.first(where: { !$0.isDirty && $0.id != activeTabId }) { tabs.removeAll { $0 === old } }
        let tab = EditorTab(id: id, path: path, isDiff: isDiff, line: line)
        tabs.append(tab); activeTabId = id; changed()
        return tab
    }

    public func select(_ tab: EditorTab) async {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tab.isDiff || tab.preview != nil || tab.loadTask != nil {
            // Open tabs already receive remote changes through filesChanged.
            // Selecting them must not restart downloads or discard their scroll state.
            activeTabId = tab.id; changed()
        } else {
            let original = tab.preview?.kind == "image" && tab.preview?.thumbnail != true
            await open(tab.path, original: original)
        }
    }

    /// Chat links can refer to either files or folders. Resolve before creating an editor tab.
    @discardableResult
    public func openReference(_ path: String, line: Int? = nil) async throws -> Bool {
        let entry = try await files.run(config, "pathInfo", ["path": .string(path)]).decode(FileEntry.self)
        if entry.directory {
            await browse(entry.path)
            if let error { throw RemoteError(error) }
            return true
        }
        await open(entry.path, line: line)
        return false
    }

    public func open(_ file: String, line: Int? = nil, original: Bool = false) async {
        let existing = tabs.first { !$0.isDiff && ($0.path == file || $0.preview?.path == file) }
        let tab = addTab(existing?.id ?? "file:" + file, path: file, isDiff: false, line: line)
        for other in tabs where other !== tab { other.loadTask?.cancel() }
        tab.loadTask?.cancel()
        let id = UUID()
        tab.loadID = id; tab.isValidating = true; tab.error = nil
        let files = self.files, config = self.config
        let task = Task { try await files.preview(config, file, original: original) }
        tab.loadTask = task
        if tab.preview == nil, let snapshot = await files.cachedPreview(config, file, original: original), tab.loadID == id {
            tab.preview = snapshot
            changed()
        }
        do {
            let result = try await task.value
            guard tab.loadID == id, tabs.contains(where: { $0 === tab }), !task.isCancelled else { return }
            if tab.isDirty {
                tab.conflict = result.version != tab.preview?.version
            } else {
                tab.preview = result; tab.path = result.path
            }
            tab.isValidating = false; tab.loadTask = nil
            changed()
            await syncWatches()
        } catch {
            guard tab.loadID == id else { return }
            tab.isValidating = false; tab.loadTask = nil
            if !(error is CancellationError) { tab.error = error.localizedDescription }
        }
        changed()
    }

    public func loadMoreText(_ tab: EditorTab) async {
        guard !tab.isValidating, var preview = tab.preview, preview.kind == "text",
              preview.truncated == true, let offset = preview.nextOffset, offset < 1024 * 1024,
              let version = preview.version else { return }
        let id = tab.loadID
        tab.isValidating = true; changed()
        defer { if tab.loadID == id { tab.isValidating = false; changed() } }
        do {
            let page = try await files.run(config, "textPage", ["path": .string(preview.path), "offset": .number(Double(offset)), "version": .string(version)])
            guard tab.loadID == id, tab.preview?.version == version, !tab.isDirty else { return }
            preview.text = (preview.text ?? "") + (page["text"]?.string ?? "")
            preview.nextOffset = page["nextOffset"]?.int
            preview.truncated = page["truncated"]?.bool
            preview.revision = page["revision"]?.string
            tab.preview = preview; tab.error = nil
        } catch { if tab.loadID == id { tab.error = error.localizedDescription } }
    }

    public func openDiff(_ file: String) async {
        let tab = addTab("diff:" + file, path: file, isDiff: true, line: nil)
        do { tab.diffText = try await files.run(config, "gitFileDiff", ["path": .string(file)])["text"]?.string ?? ""; tab.error = nil }
        catch { tab.error = error.localizedDescription }
        changed()
    }

    /// The caller confirms discarding unsaved edits first.
    public func close(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.loadTask?.cancel()
        tab.loadID = UUID()
        tabs.remove(at: index)
        if activeTabId == tab.id { activeTabId = (tabs[safe: index] ?? tabs[safe: index - 1])?.id }
        changed()
        Task { await syncWatches() }
    }

    public func beginEditing(_ tab: EditorTab) { if !tab.isValidating, tab.error == nil, tab.preview?.kind == "text", tab.preview?.truncated != true { tab.draft = tab.preview?.text; changed() } }

    public func save(_ tab: EditorTab) async {
        guard let draft = tab.draft, let preview = tab.preview, let revision = preview.revision else { return }
        do {
            let saved = try await files.save(config, preview.path, text: draft, revision: revision)
            tab.preview = saved; tab.draft = saved.text; tab.conflict = false; tab.notice = "已保存到远端"
        } catch { tab.notice = error.localizedDescription }
        changed()
    }

    // MARK: Entry operations

    public func createEntry(in directory: String, name: String, folder: Bool) async throws {
        let created = try await files.run(config, "create", ["directory": .string(directory), "name": .string(name), "folder": .bool(folder)]).decode(FileEntry.self)
        files.invalidate(config)
        if directory != root { expanded.insert(directory) }
        await reload(force: true)
        if !folder { await open(created.path) }
    }

    public func rename(_ entry: FileEntry, to name: String) async throws {
        _ = try await files.run(config, "rename", ["path": .string(entry.path), "name": .string(name)])
        files.invalidate(config)
        await reload(force: true)
    }

    public func remove(_ entry: FileEntry) async throws {
        _ = try await files.run(config, "remove", ["path": .string(entry.path), "recursive": .bool(entry.directory)])
        files.invalidate(config)
        await reload(force: true)
    }

    public func search(_ query: String) async throws -> SearchResult {
        try await files.run(config, "search", ["query": .string(query)], timeout: 25).decode(SearchResult.self)
    }

    public func suggest(_ query: String) async throws -> [FileEntry] {
        (try await files.run(config, "suggest", ["query": .string(query)])["files"] ?? []).array?.compactMap { try? $0.decode(FileEntry.self) } ?? []
    }
}

#if DEBUG
extension Workspace {
    /// Documentation fixtures only: a file tree and open tabs without a server.
    public func seedPreview(root: String, rows: [(entry: FileEntry, depth: Int, expanded: Bool, git: String?)], files: [FilePreview], diff: (path: String, text: String)?, active: String?, git: GitStatus?) {
        self.root = root
        self.rows = rows.map { TreeRow(entry: $0.entry, depth: $0.depth, expanded: $0.expanded, gitCode: $0.git, touched: false) }
        self.gitStatus = git
        var opened: [EditorTab] = files.map { file in
            let tab = EditorTab(id: file.path, path: file.path, isDiff: false)
            tab.preview = file
            return tab
        }
        if let diff {
            let tab = EditorTab(id: "diff:" + diff.path, path: diff.path, isDiff: true)
            tab.diffText = diff.text
            opened.append(tab)
        }
        tabs = opened
        activeTabId = active
        footer = "\(rows.count) 项"
        onChange?()
    }
}
#endif
