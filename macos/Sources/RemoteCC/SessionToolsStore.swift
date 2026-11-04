import SwiftUI
import RemoteCCCore

enum SessionToolSection: String {
    case skills, commands, mcp, plugins, agents, tasks, config, models, tools, status, ssh
    var needsRuntime: Bool { [.mcp, .skills, .plugins, .config].contains(self) }
}

/// A page owns its requests. Leaving it invalidates every pending result, including mutations.
@MainActor
final class SessionToolsStore: ObservableObject {
    @Published private(set) var content: JSON?
    @Published private(set) var runtime: JSON?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var generation = UUID()
    private var operation: Task<Void, Never>?

    func invalidate() {
        generation = UUID()
        operation?.cancel(); operation = nil
        busy = false; content = nil; runtime = nil; message = nil
    }

    func load(section: SessionToolSection, read: (String) async throws -> JSON) async {
        invalidate()
        let request = generation
        content = nil; runtime = nil; message = nil; busy = true
        defer { if generation == request { busy = false } }
        do {
            let runtimeValue = section.needsRuntime ? try await read("runtimeStatus") : nil
            try Task.checkCancellation()
            guard generation == request else { return }
            let contentValue = [.mcp, .config].contains(section) ? nil : try await read(section.rawValue)
            try Task.checkCancellation()
            guard generation == request else { return }
            runtime = runtimeValue; content = contentValue
        } catch is CancellationError { }
        catch { if generation == request { message = error.localizedDescription } }
    }

    func perform(_ action: @escaping () async throws -> (content: JSON?, runtime: JSON?, message: String)) {
        guard !busy else { return }
        let request = generation
        busy = true; message = nil
        operation = Task {
            defer { if generation == request { busy = false; operation = nil } }
            do {
                let value = try await action()
                try Task.checkCancellation()
                guard generation == request else { return }
                content = value.content; runtime = value.runtime; message = value.message
            } catch is CancellationError { }
            catch { if generation == request { message = error.localizedDescription } }
        }
    }
}
