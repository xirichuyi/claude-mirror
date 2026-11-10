import SwiftUI
import RemoteCCCore

/// Shared by the account menu and details sheet; independent of sidebar visibility.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var status: JSON?
    @Published private(set) var failure: String?
    @Published private(set) var refreshing = false
    private var source = ""
    private var generation = UUID()
    private var loader: (() async throws -> JSON)?
    private var pending: Task<JSON, Error>?

    func observe(source: String, loader: (() async throws -> JSON)?) async {
        pending?.cancel()
        pending = nil
        self.source = source
        self.loader = loader
        generation = UUID()
        let observation = generation
        status = nil; failure = nil; refreshing = false
        guard loader != nil else { return }
        while !Task.isCancelled && generation == observation {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
        }
    }

    func refresh() async {
        guard let loader else { return }
        if let pending { _ = try? await pending.value; return }
        let request = generation
        refreshing = true
        let task = Task { try await loader() }
        pending = task
        defer {
            if generation == request { pending = nil; refreshing = false }
        }
        do {
            let value = try await task.value
            guard generation == request else { return }
            status = value
            failure = value["quotaError"]?.string ?? (value["quota"]?["available"]?.isTruthy == true ? nil : "无法确认订阅额度，远端将暂停新请求")
        } catch {
            guard generation == request else { return }
            // Retain account identity during a transient network failure. Quota views
            // use failure to hide stale percentages until a successful refresh.
            failure = "额度读取失败：" + error.localizedDescription
        }
    }
}
