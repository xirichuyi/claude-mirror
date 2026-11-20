import SwiftUI
import Observation
import RemoteCCCore

/// Search belongs to a workspace, so moving between tools does not discard it.
@MainActor @Observable
final class WorkspaceSearchState {
    var query = "" {
        didSet { if query != oldValue { cancel(); matches = []; status = "" } }
    }
    private(set) var status = ""
    private(set) var matches: [SearchMatch] = []
    private(set) var searching = false
    private var root: String?
    private var task: Task<Void, Never>?

    func updateRoot(_ value: String?) {
        guard root != value else { return }
        root = value
        cancel(); matches = []; status = ""
    }

    private func cancel() { task?.cancel(); searching = false }

    func run(in workspace: Workspace, delay: Bool = false) {
        cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        updateRoot(workspace.root)
        let searchedRoot = workspace.root
        status = ""; matches = []; searching = true
        task = Task { [weak self] in
            do {
                if delay { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                let result = try await workspace.search(term)
                guard !Task.isCancelled, let self else { return }
                guard workspace.root == searchedRoot else { self.updateRoot(workspace.root); return }
                self.matches = result.matches
                self.status = result.matches.isEmpty ? "无匹配" : "\(result.matches.count) 处匹配" + (result.truncated == true ? " · 部分结果" : "")
                self.searching = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.status = error.localizedDescription; self.searching = false
            }
        }
    }
}
