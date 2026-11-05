import Foundation

/// Cancelling one viewer does not interrupt another viewer of the same file.
final class SharedFileRequests<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                if entries[key] != nil {
                    entries[key]?.waiters[waiter] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        self.finish(key, id: id, result: result)
                    }
                    entries[key] = Entry(id: id, task: task, waiters: [waiter: continuation])
                }
                lock.unlock()
            }
        } onCancel: { self.cancel(key, waiter: waiter) }
    }

    private func finish(_ key: String, id: UUID, result: Result<Value, Error>) {
        let entry = lock.withLock { () -> Entry? in
            guard entries[key]?.id == id else { return nil }
            return entries.removeValue(forKey: key)
        }
        entry?.waiters.values.forEach { $0.resume(with: result) }
    }

    private func cancel(_ key: String, waiter: UUID) {
        lock.lock()
        let continuation = entries[key]?.waiters.removeValue(forKey: waiter)
        let abandoned = entries[key]?.waiters.isEmpty == true ? entries.removeValue(forKey: key) : nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        abandoned?.task.cancel()
    }
}
