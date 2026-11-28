import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct TransferProgress: Sendable {
    public var config: ConnectionConfig
    public var name: String
    public var bytes: Int
    public var total: Int
    public var finished: Bool
    public var error: String?
}

public struct UploadResult: Sendable {
    public let file: URL
    public let attachment: Attachment?
    public let error: String?
}

/// Stable file name for a cache key; collisions only mean a re-download check by version.
private func cacheName(_ key: String) -> String {
    var first: UInt64 = 0xcbf29ce484222325, second: UInt64 = 0x84222325cbf29ce4
    for byte in key.utf8 {
        first = (first ^ UInt64(byte)) &* 0x100000001b3
        second = (second &+ UInt64(byte)) &* 0x100000001b3
    }
    return String(first, radix: 16) + String(second, radix: 16)
}

public final class RemoteFiles: @unchecked Sendable {
    private let agents: AgentClient
    private let cacheDirectory: URL
    private let cacheLimit: Int
    private let lock = NSLock()
    private let previewRequests = SharedFileRequests<FilePreview>()
    private let contentRequests = SharedFileRequests<URL>()
    private var previews: [String: FilePreview] = [:]
    private var activePartials: Set<String> = []
    private var listings: [String: (time: Date, value: DirectoryListing)] = [:]
    public var onProgress: (@Sendable (TransferProgress) -> Void)?

    public init(agents: AgentClient, cacheDirectory: URL, cacheLimit: Int = 256 * 1024 * 1024) {
        self.agents = agents; self.cacheDirectory = cacheDirectory; self.cacheLimit = cacheLimit
    }

    public func run(_ config: ConnectionConfig, _ operation: String, _ params: [String: JSON] = [:], timeout: TimeInterval = 45) async throws -> JSON {
        var request = params
        request["operation"] = .string(operation)
        request["base"] = .string(config.directory)
        return try await agents.call(config, "file", .object(request), timeout: timeout, files: true)
    }

    public func createFolder(_ config: ConnectionConfig, in parent: String, name: String) async throws -> FileEntry {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw RemoteError("请输入有效的文件夹名称") }
        let entry = try await run(config, "create", ["directory": .string(parent), "name": .string(name), "folder": .bool(true)]).decode(FileEntry.self)
        invalidate(config)
        return entry
    }

    public func invalidate(_ config: ConnectionConfig? = nil) {
        lock.withLock {
            if let config { listings = listings.filter { !$0.key.hasPrefix(config.key + "|") } }
            else { listings = [:] }
        }
    }

    public func list(_ config: ConnectionConfig, _ folder: String, hidden: Bool, force: Bool = false) async throws -> DirectoryListing {
        let key = "\(config.key)|\(config.directory)|\(folder)|\(hidden)"
        if !force {
            let cached = lock.withLock { listings[key] }
            if let cached, Date().timeIntervalSince(cached.time) < 3 { return cached.value }
        }
        let value = try await run(config, "list", ["path": .string(folder), "hidden": .bool(hidden)]).decode(DirectoryListing.self)
        lock.withLock { listings[key] = (Date(), value) }
        return value
    }

    private func previewKey(_ config: ConnectionConfig, _ file: String, original: Bool) -> String {
        "\(config.key)|\(config.directory)|\(file)|\(original)"
    }

    private func contentURL(_ config: ConnectionConfig, _ info: FilePreview) -> URL {
        cacheDirectory.appendingPathComponent(cacheName("\(config.key)|\(info.path)|\(info.version ?? "")|\(info.thumbnail == true)"))
    }

    /// Unvalidated snapshot for immediate display only. Saves still require a remote revision check.
    public func cachedPreview(_ config: ConnectionConfig, _ file: String, original: Bool = false) async -> FilePreview? {
        let key = previewKey(config, file, original: original)
        let disk = cacheDirectory.appendingPathComponent(cacheName("preview:" + key))
        guard var info = lock.withLock({ previews[key] }) ?? (try? JSONDecoder().decode(FilePreview.self, from: Data(contentsOf: disk))) else { return nil }
        if info.kind == "image" || info.kind == "pdf" {
            guard let data = try? Data(contentsOf: contentURL(config, info), options: .mappedIfSafe) else { return nil }
            info.data = data
        }
        return info
    }

    public func preview(_ config: ConnectionConfig, _ file: String, original: Bool = false) async throws -> FilePreview {
        let key = previewKey(config, file, original: original)
        return try await previewRequests.value(for: key) {
            try await self.fetchPreview(config, file, original: original)
        }
    }

    /// Fetches an image's thumbnail before it is asked for. An original is never downloaded for this.
    public func warm(_ config: ConnectionConfig, _ file: String) async {
        let key = "warm:" + previewKey(config, file, original: false)
        _ = try? await previewRequests.value(for: key) {
            try await self.fetchPreview(config, file, original: false, thumbnailOnly: true)
        }
    }

    private func fetchPreview(_ config: ConnectionConfig, _ file: String, original: Bool, thumbnailOnly: Bool = false) async throws -> FilePreview {
        let key = previewKey(config, file, original: original)
        let previous = await cachedPreview(config, file, original: original)
        var params: [String: JSON] = ["path": .string(file), "inlineMedia": .bool(true), "thumbnail": .bool(!original), "textLimit": .number(65536)]
        if let version = previous?.version { params["knownVersion"] = .string(version) }
        let response = try await run(config, "preview", params)
        try Task.checkCancellation()
        var info = try response.decode(FilePreview.self)
        if info.notModified == true, let previous { return previous }
        if thumbnailOnly && info.kind != "text" && info.thumbnail != true && response["inlineData"] == nil { throw CancellationError() }
        if info.kind == "image" || info.kind == "pdf" {
            let inline = response["inlineData"]?.string.flatMap { Data(base64Encoded: $0) }
            info.data = try Data(contentsOf: try await cached(config, info, inline: inline), options: .mappedIfSafe)
        }
        if info.kind == "text", info.truncated != true, let text = info.text {
            _ = try? await cached(config, info, inline: Data(text.utf8))
        }
        try Task.checkCancellation()
        var metadata = info
        metadata.data = nil
        lock.withLock {
            if previews.count >= 32 { previews.removeAll() }
            previews[key] = metadata
        }
        // Disk caching is best effort; a full disk must not hide a successful preview.
        let target = cacheDirectory.appendingPathComponent(cacheName("preview:" + key))
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? JSONEncoder().encode(metadata).write(to: target, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        pruneCache(keeping: target)
        return info
    }

    public func save(_ config: ConnectionConfig, _ file: String, text: String, revision: String) async throws -> FilePreview {
        defer { invalidate(config) }
        return try await run(config, "save", ["path": .string(file), "revision": .string(revision), "data": .string(text)]).decode(FilePreview.self)
    }

    public func stat(_ config: ConnectionConfig, _ file: String) async throws -> FileEntry {
        try await run(config, "stat", ["path": .string(file)]).decode(FileEntry.self)
    }

    private func cached(_ config: ConnectionConfig, _ info: FilePreview, inline: Data? = nil) async throws -> URL {
        let key = contentURL(config, info).path
        return try await contentRequests.value(for: key) {
            try await self.cacheContent(config, info, inline: inline)
        }
    }

    private func cacheContent(_ config: ConnectionConfig, _ info: FilePreview, inline: Data?) async throws -> URL {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = contentURL(config, info)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temporary = cacheDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let inline, inline.count == info.size || (info.thumbnail == true && inline.count <= 512 * 1024) {
            try inline.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        } else {
            guard info.thumbnail != true else { throw RemoteError("缩略图数据不完整，请重试") }
            try await transferDown(config, path: info.path, version: info.version, name: info.name, size: info.size, to: temporary)
        }
        if rename(temporary.path, target.path) != 0 {
            throw RemoteError("无法写入预览缓存：" + String(cString: strerror(errno)))
        }
        pruneCache(keeping: target)
        return target
    }

    private func pruneCache(keeping: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }
        let items = files.compactMap { url -> (URL, Date, Int)? in
            guard !url.lastPathComponent.hasSuffix(".tmp"), !lock.withLock({ activePartials.contains(url.lastPathComponent) }), let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = items.reduce(0) { $0 + $1.2 }
        for item in items where total > cacheLimit && item.0 != keeping {
            try? FileManager.default.removeItem(at: item.0)
            total -= item.2
        }
    }

    /// Downloads over the agent channel. A versioned download that breaks keeps its bytes and resumes next time.
    private func transferDown(_ config: ConnectionConfig, path: String, version: String?, name: String, size: Int, to destination: URL) async throws {
        let partial = version.map { cacheDirectory.appendingPathComponent(cacheName("\(config.key)|\(path)|\($0)") + ".partial") }
        let target = partial ?? destination
        let existing = partial.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue } ?? 0
        let offset = existing <= size ? existing : 0
        if let partial {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            lock.withLock { _ = activePartials.insert(partial.lastPathComponent) }
        }
        defer { if let partial { lock.withLock { _ = activePartials.remove(partial.lastPathComponent) } } }
        if offset == 0 || partial == nil {
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RemoteError("无法写入本地文件") }
        }
        guard let output = try? FileHandle(forWritingTo: target) else { throw RemoteError("无法写入本地文件") }
        final class Counter: @unchecked Sendable { var bytes = 0; var last = Date.distantPast }
        let counter = Counter()
        let progress = onProgress
        var request: JSON = ["path": .string(path), "base": .string(config.directory)]
        if let version { request["version"] = .string(version) }
        do {
            try output.seek(toOffset: UInt64(offset))
            counter.bytes = offset
            let channel = try await agents.channel(config, files: true)
            _ = try await channel.read(request, offset: offset, into: output) { count in
                counter.bytes += count
                if Date().timeIntervalSince(counter.last) > 0.15 {
                    counter.last = Date()
                    progress?(TransferProgress(config: config, name: name, bytes: counter.bytes, total: size, finished: false))
                }
            }
            try output.close()
            guard counter.bytes == size else { throw RemoteError("下载未完成（\(counter.bytes)/\(size)），可重试") }
            if let partial, rename(partial.path, destination.path) != 0 {
                guard errno == EXDEV else { throw RemoteError("无法写入本地文件：" + String(cString: strerror(errno))) }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: partial, to: destination)
                try? FileManager.default.removeItem(at: partial)
            }
        } catch {
            try? output.close()
            // A changed file can never resume; keep only bytes of the version that was asked for.
            if let partial, error.localizedDescription.contains("已变化") { try? FileManager.default.removeItem(at: partial) }
            let message = error is CancellationError ? "请求已取消" : error.localizedDescription
            progress?(TransferProgress(config: config, name: name, bytes: counter.bytes, total: size, finished: true, error: message))
            throw error
        }
        progress?(TransferProgress(config: config, name: name, bytes: counter.bytes, total: size, finished: true))
    }

    public func download(_ config: ConnectionConfig, _ file: String, to destination: URL) async throws {
        let info = try await stat(config, file)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".remotecc-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preview = try JSONDecoder().decode(FilePreview.self, from: JSONEncoder().encode(info))
        // Shares one transfer with a preview of the same file: two writers on one .partial corrupt it,
        // and whichever finishes first renames it away from the other.
        // Files larger than the cache go straight to the destination; previews never fetch those.
        if info.size <= cacheLimit {
            let hit = FileManager.default.fileExists(atPath: contentURL(config, preview).path)
            let local = try await cached(config, preview)
            try FileManager.default.copyItem(at: local, to: temporary)
            if hit { onProgress?(TransferProgress(config: config, name: info.name, bytes: info.size, total: info.size, finished: true)) }
        } else {
            try await transferDown(config, path: info.path, version: info.version, name: info.name, size: info.size, to: temporary)
        }

        // Same-filesystem rename is atomic and refuses to replace a directory.
        // Never remove the previous destination before the replacement succeeds.
        guard rename(temporary.path, destination.path) == 0 else {
            let message = "无法替换下载目标：" + String(cString: strerror(errno))
            onProgress?(TransferProgress(config: config, name: info.name, bytes: info.size, total: info.size, finished: true, error: message))
            throw RemoteError(message)
        }
    }

    /// Overlap per-file setup and ACK waits while keeping bulk concurrency bounded.
    /// Duplicate basenames stay serial so the first selected file wins deterministically.
    public func uploadBatch(_ config: ConnectionConfig, files urls: [URL], directory: String? = nil,
                            onCompletion: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async -> [UploadResult] {
        guard !urls.isEmpty else { return [] }
        let width = Set(urls.map(\.lastPathComponent)).count == urls.count ? 2 : 1
        var results = Array<UploadResult?>(repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, UploadResult).self) { group in
            func enqueue(_ index: Int) {
                group.addTask {
                    let url = urls[index]
                    do {
                        try Task.checkCancellation()
                        let attachment = try await self.upload(config, file: url, directory: directory)
                        return (index, UploadResult(file: url, attachment: attachment, error: nil))
                    } catch { return (index, UploadResult(file: url, attachment: nil, error: error.localizedDescription)) }
                }
            }
            var next = 0, completed = 0
            for _ in 0..<min(width, urls.count) { enqueue(next); next += 1 }
            for await (index, result) in group {
                results[index] = result; completed += 1
                await onCompletion(completed, urls.count)
                if next < urls.count && !Task.isCancelled { enqueue(next); next += 1 }
            }
        }
        return urls.indices.map { results[$0] ?? UploadResult(file: urls[$0], attachment: nil, error: "上传已取消") }
    }

    public func upload(_ config: ConnectionConfig, file: URL, directory: String? = nil) async throws -> Attachment {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular, size <= 1024 * 1024 * 1024 else { throw RemoteError("请选择不超过 1 GB 的普通文件") }
        let name = file.lastPathComponent
        var request: JSON = ["operation": "upload", "name": .string(name), "size": .number(Double(size)), "base": .string(config.directory)]
        if let directory { request["directory"] = .string(directory) }
        else {
            let digest = try attachmentDigest(file)
            let lookup = try await run(config, "attachmentLookup", ["name": .string(name), "digest": .string(digest)], timeout: 120)
            if let value = lookup["file"], value != .null {
                let entry = try value.decode(FileEntry.self)
                return Attachment(name: name, path: entry.path, size: entry.size)
            }
            request["attachment"] = .bool(true)
            request["digest"] = .string(digest)
        }
        final class Sent: @unchecked Sendable { var bytes = 0; var last = Date.distantPast }
        let sent = Sent()
        let progress = onProgress
        let entry: FileEntry
        do {
            let channel = try await agents.channel(config, files: true)
            let reply = try await channel.write(request, file: file) { total in
                sent.bytes = total
                if Date().timeIntervalSince(sent.last) > 0.15 {
                    sent.last = Date()
                    progress?(TransferProgress(config: config, name: name, bytes: total, total: size, finished: false))
                }
            }
            invalidate(config)
            entry = try reply.decode(FileEntry.self)
        } catch {
            invalidate(config)
            progress?(TransferProgress(config: config, name: name, bytes: sent.bytes, total: size, finished: true, error: error.localizedDescription))
            throw error
        }
        guard entry.size == size else { throw RemoteError("上传文件大小不一致，请重试") }
        onProgress?(TransferProgress(config: config, name: name, bytes: size, total: size, finished: true))
        return Attachment(name: entry.name, path: entry.path, size: entry.size)
    }
}

func attachmentDigest(_ file: URL) throws -> String {
#if canImport(CryptoKit)
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var hash = SHA256()
    while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
#else
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["sha256sum", "--", file.path]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8), text.count >= 64 else { throw RemoteError("无法计算附件摘要") }
    return String(text.prefix(64))
#endif
}
