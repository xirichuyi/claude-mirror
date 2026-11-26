import Foundation

/// Files built from `src/` by scripts/prepare-server.cts and shipped inside the app.
public struct ServerResources: Sendable {
    public let agentSource: Data
    public let agentDigest: String
    public let bundleDigest: String
    public let bundlePayload: String
    /// scripts/install-claude-remote.sh, run over SSH for one-click server setup.
    public let installScript: Data?

    public init(directory: URL) throws {
        installScript = try? Data(contentsOf: directory.appendingPathComponent("install-claude-remote.sh"))
        agentSource = try Data(contentsOf: directory.appendingPathComponent("remote-agent.cjs"))
        let manifest = try JSON.parse(try Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard let agent = manifest["agentDigest"]?.string, let digest = manifest["bundleDigest"]?.string, let payload = manifest["bundlePayload"]?.string else {
            throw RemoteError("应用内的服务端程序不完整，请重新构建")
        }
        agentDigest = agent; bundleDigest = digest; bundlePayload = payload
    }
}

/// One persistent SSH channel to remote-agent.cjs, multiplexing every small request.
public final class AgentChannel: @unchecked Sendable {
    private struct Pending { let continuation: CheckedContinuation<JSON, Error> }
    public struct Subscription: Sendable {
        let cancel: @Sendable () -> Void
        public func kill() { cancel() }
    }
    private struct Watch { let packet: @Sendable (JSON) -> Void; let end: @Sendable (String) -> Void }
    private struct Stream { let data: @Sendable (Data) -> Void; let end: @Sendable (String?) -> Void }
    /// Upload credit granted by the agent; `offset` arrives once, before any credit.
    private final class Upload: @unchecked Sendable {
        let lock = NSLock()
        var offset: Int?
        var credit = 0
        var failure: String?
        var waiter: CheckedContinuation<Void, Never>?
        func update(_ change: (Upload) -> Void) {
            lock.lock(); change(self); let resume = waiter; waiter = nil; lock.unlock()
            resume?.resume()
        }
        func wait(until ready: (Upload) -> Bool) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if ready(self) || failure != nil { lock.unlock(); continuation.resume() }
                else { waiter = continuation; lock.unlock() }
            }
        }
    }

    private let lock = NSLock()
    private let launcher: RemoteLauncher
    private let config: ConnectionConfig
    private let resources: ServerResources
    private var child: RemoteProcess?
    private var pending: [Int: Pending] = [:]
    private var subscriptions: [String: Watch] = [:]
    private var streams: [Int: Stream] = [:]
    private var uploads: [Int: Upload] = [:]
    private var framed = false
    private var upgradeID = -1
    private var sequence = 0
    private var closed = false
    public private(set) var info: ServerInfo?
    var onFileChange: (@Sendable ([String]) -> Void)?
    var onClosed: (@Sendable () -> Void)?

    init(launcher: RemoteLauncher, config: ConnectionConfig, resources: ServerResources) {
        self.launcher = launcher; self.config = config; self.resources = resources
    }

    private var agentFile: String { "$HOME/.local/share/remotecc/agent/\(resources.agentDigest)/remote-agent.cjs" }

    // Non-interactive login shells often miss nvm/fnm/volta, so look there before giving up on node.
    private var bootstrap: String {
        """
        A="\(agentFile)"
        M="$HOME/.local/share/claude-mirror/node/bin"
        if [ -x "$M/node" ]; then
          PATH="$M:$PATH"
        elif ! command -v node >/dev/null 2>&1; then
          for N in "$HOME"/.nvm/versions/node/*/bin/node "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node "$HOME"/.fnm/node-versions/*/installation/bin/node "$HOME"/.volta/bin/node "$HOME"/.asdf/shims/node /usr/local/bin/node /opt/homebrew/bin/node; do
            [ -x "$N" ] && PATH="$(dirname "$N"):$PATH"
          done
        fi
        PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:$HOME/.npm-global/bin"
        export PATH
        command -v node >/dev/null 2>&1 || { echo __RCC_NO_NODE__; exit 0; }
        V="$(node --version 2>/dev/null)"; V="${V#v}"; J="${V%%.*}"; R="${V#*.}"; R="${R%%.*}"
        case "$J$R" in *[!0-9]*|"") ;; *) if [ "$J" -lt 18 ] || { [ "$J" -eq 18 ] && [ "$R" -lt 14 ]; }; then echo "__RCC_OLD_NODE__ v$V"; exit 0; fi ;; esac
        [ -f "$A" ] || { echo __RCC_INSTALL__; exit 0; }
        exec node "$A"
        """
    }

    // The outer `sh -c` keeps this valid when the account's login shell is fish or csh.
    private var startCommand: String {
        "sh -c " + shellQuote("if command -v bash >/dev/null 2>&1; then exec bash -lc \(shellQuote(bootstrap)); else exec sh -lc \(shellQuote(bootstrap)); fi")
    }

    private var installCommand: String {
        "sh -c " + shellQuote("D=\"$(dirname \"\(agentFile)\")\"; T=\"$D/.install.$$\"; mkdir -p \"$D\" && chmod 700 \"$D\" && cat > \"$T\" && [ \"$(wc -c < \"$T\" | tr -d ' ')\" = \"\(resources.agentSource.count)\" ] && mv \"$T\" \"\(agentFile)\" || { rm -f \"$T\"; echo \"无法写入远端代理程序\" >&2; exit 1; }")
    }

    func start() async throws {
        var outcome = try await launch()
        if outcome == "install" {
            try await install()
            outcome = try await launch()
        }
        guard outcome == "ready" else { throw RemoteError("远端代理启动失败") }
        let id: Int = lock.withLock { sequence += 1; upgradeID = sequence; return sequence }
        _ = try await call("frames", ["version": 1], id: id)
        let hello = try await call("file", ["operation": "hello"])
        let server = try hello.decode(ServerInfo.self)
        guard server.nodeSupported else {
            close()
            throw RemoteSetupError.nodeOutdated(server.node ?? "未知版本")
        }
        lock.withLock { info = server }
    }

    private final class LaunchState: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<String, Error>?
        var buffer = WireBuffer()
        var ready = false
        func settle(_ result: Result<String, Error>) {
            lock.lock(); let waiting = continuation; continuation = nil; lock.unlock()
            waiting?.resume(with: result)
        }
    }

    private func launch() async throws -> String {
        let process = try launcher.spawn(config, command: startCommand)
        let state = LaunchState()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            let timer = DispatchWorkItem { state.settle(.failure(RemoteError("远端代理启动超时"))); process.kill() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
            process.readOutput(chunk: { [weak self] data in
                var lines: [Data] = []
                state.buffer.append(data, line: { line in
                    guard state.ready else { lines.append(line); return false }
                    return line.first == UInt8(ascii: "{") && (self?.receive(line) ?? false)
                }, frame: { type, id, payload in self?.receive(frame: type, id: id, payload) })
                for line in lines {
                    // Profile scripts may print anything; ignore lines until the handshake.
                    let text = String(decoding: line, as: UTF8.self)
                    if text == "__RCC_INSTALL__" { timer.cancel(); state.settle(.success("install")) }
                    else if text == "__RCC_NO_NODE__" { timer.cancel(); state.settle(.failure(RemoteSetupError.nodeMissing)) }
                    else if text.hasPrefix("__RCC_OLD_NODE__ ") { timer.cancel(); state.settle(.failure(RemoteSetupError.nodeOutdated(String(text.dropFirst("__RCC_OLD_NODE__ ".count))))) }
                    else if text.hasPrefix("{\"rcc\":\"ready\"") {
                        state.ready = true
                        self?.setChild(process)
                        timer.cancel(); state.settle(.success("ready"))
                    }
                }
            }, done: { [weak self] in
                timer.cancel()
                Task {
                    _ = await process.waitForExit()
                    let reason = process.stderrText
                    state.settle(.failure(RemoteError(reason.isEmpty ? "远端代理已退出" : reason)))
                    // The install probe exits by design; only losing a running agent ends the channel.
                    if state.ready { self?.shutdown(reason.isEmpty ? "SSH 通道已断开" : reason) }
                }
            })
        }
    }

    private func setChild(_ process: RemoteProcess) { lock.lock(); child = process; lock.unlock() }

    private func install() async throws {
        let process = try launcher.spawn(config, command: installCommand)
        process.readOutput(chunk: { _ in }, done: {})
        process.write(resources.agentSource)
        process.closeInput()
        if await process.waitForExit() != 0 { throw RemoteError(process.stderrText.isEmpty ? "无法安装远端代理" : process.stderrText) }
    }

    /// Returns true for the reply that switches the channel to frames.
    @discardableResult
    private func receive(_ line: Data, inline: Data? = nil) -> Bool {
        guard var message = try? JSON.parse(line) else { return false }
        if message["event"]?.string == "fs" {
            onFileChange?((message["directories"]?.array ?? []).compactMap(\.string))
            return false
        }
        if let stream = message["stream"]?.int {
            let upload = lock.withLock { uploads[stream] }
            upload?.update { $0.offset = message["offset"]?.int ?? 0 }
            return false
        }
        if let inline, case .object(var result)? = message["result"] {
            result["inlineData"] = .string(inline.base64EncodedString())
            message["result"] = .object(result)
        }
        if let subscription = message["sub"]?.string {
            lock.lock()
            let watch = subscriptions[subscription]
            let ended = message["end"]?.isTruthy == true
            if ended { subscriptions[subscription] = nil }
            lock.unlock()
            if ended { watch?.end(message["error"]?.string ?? "") }
            else if let packet = message["packet"] { watch?.packet(packet) }
            return false
        }
        guard let id = message["id"]?.int else { return false }
        lock.lock()
        let request = pending.removeValue(forKey: id)
        let upgraded = id == upgradeID && !framed && message["result"]?["version"]?.int == 1
        if upgraded { framed = true }
        lock.unlock()
        if let error = message["error"]?.string { request?.continuation.resume(throwing: RemoteError(error)) }
        else { request?.continuation.resume(returning: message["result"] ?? .null) }
        return upgraded
    }

    private func receive(frame type: UInt8, id: Int, _ payload: Data) {
        switch type {
        case FrameType.json: receive(payload)
        case FrameType.blob where payload.count >= 4:
            let length = Int(WireBuffer.uint32(payload, payload.startIndex))
            guard payload.count >= 4 + length else { return }
            let start = payload.startIndex + 4
            receive(Data(payload[start..<(start + length)]), inline: Data(payload[(start + length)...]))
        case FrameType.data:
            lock.withLock { streams[id] }?.data(payload)
        case FrameType.end:
            let stream = lock.withLock { streams.removeValue(forKey: id) }
            stream?.end(payload.isEmpty ? nil : String(decoding: payload, as: UTF8.self))
        case FrameType.credit where payload.count >= 4:
            let bytes = Int(WireBuffer.uint32(payload, payload.startIndex))
            lock.withLock { uploads[id] }?.update { $0.credit += bytes }
        default: break
        }
    }

    private func write(_ value: JSON) {
        lock.lock(); let process = child; let framed = framed; lock.unlock()
        guard var data = try? value.data() else { return }
        if framed { data = WireBuffer.frame(FrameType.json, 0, data) } else { data.append(10) }
        process?.write(data)
    }

    private func writeFrame(_ type: UInt8, _ id: Int, _ payload: Data = Data()) {
        lock.lock(); let process = child; lock.unlock()
        process?.write(WireBuffer.frame(type, id, payload))
    }

    private func nextID() -> Int { lock.withLock { sequence += 1; return sequence } }

    /// Streams a remote file into `output` from `offset`; returns the reply (`size`, `version`, `offset`) once the stream ends.
    public func read(_ params: JSON, offset: Int, into output: FileHandle, received: @escaping @Sendable (Int) -> Void) async throws -> JSON {
        let id = nextID()
        final class State: @unchecked Sendable { var failed = false }
        let state = State()
        let ended = AsyncThrowingStream<Void, Error> { continuation in
            let stream = Stream(data: { [weak self] data in
                guard !state.failed else { return }
                do { try output.write(contentsOf: data) } catch { state.failed = true; continuation.finish(throwing: RemoteError("无法写入本地文件")); return }
                received(data.count)
                var credit = Data(count: 4)
                credit.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(data.count).bigEndian, as: UInt32.self) }
                self?.writeFrame(FrameType.credit, id, credit)
            }, end: { error in
                if let error { continuation.finish(throwing: RemoteError(error)) } else { continuation.finish() }
            })
            self.lock.withLock { self.streams[id] = stream }
        }
        var request = params
        request["operation"] = "read"
        request["offset"] = .number(Double(offset))
        request["window"] = .number(Double(1024 * 1024))
        return try await withTaskCancellationHandler {
            do {
                let reply = try await call("file", request, id: id)
                for try await _ in ended {}
                return reply
            } catch {
                lock.withLock { streams[id] = nil }
                throw error
            }
        } onCancel: {
            self.write(["cancel": .number(Double(id))])
            let stream = self.lock.withLock { self.streams.removeValue(forKey: id) }
            stream?.end("请求已取消")
        }
    }

    /// Sends `file` from the offset the agent asks for (non-zero when it kept a partial attachment).
    public func write(_ params: JSON, file: URL, sent: @escaping @Sendable (Int) -> Void) async throws -> JSON {
        let id = nextID()
        let upload = Upload()
        lock.withLock { uploads[id] = upload }
        defer { lock.withLock { uploads[id] = nil } }
        var request = params
        request["operation"] = "write"
        let reply = Task { try await call("file", request, timeout: 24 * 3600, id: id) }
        let sender = Task {
            await upload.wait { $0.offset != nil }
            guard let offset = upload.lock.withLock({ upload.offset }) else { return }
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(offset))
            var total = offset
            sent(total)
            while true {
                await upload.wait { $0.credit > 0 }
                try Task.checkCancellation()
                let credit: Int = upload.lock.withLock { upload.failure == nil ? upload.credit : -1 }
                if credit < 0 { return }
                if credit == 0 { continue }
                guard let chunk = try input.read(upToCount: min(credit, 128 * 1024)), !chunk.isEmpty else { break }
                upload.lock.withLock { upload.credit -= chunk.count }
                writeFrame(FrameType.data, id, chunk)
                total += chunk.count
                sent(total)
            }
            writeFrame(FrameType.end, id)
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await reply.value
                sender.cancel()
                return result
            } catch {
                upload.update { $0.failure = error.localizedDescription }
                sender.cancel()
                throw error
            }
        } onCancel: {
            reply.cancel()
        }
    }

    public func call(_ op: String, _ params: JSON, timeout: TimeInterval = 60, id requested: Int? = nil) async throws -> JSON {
        let id = requested ?? nextID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, Error>) in
                lock.lock()
                if closed || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: RemoteError(closed ? "SSH 通道已断开" : "请求已取消"))
                    return
                }
                pending[id] = Pending(continuation: continuation)
                lock.unlock()
                write(["id": .number(Double(id)), "op": .string(op), "params": params])
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.fail(id, "远端操作超时") }
            }
        } onCancel: { self.fail(id, "请求已取消") }
    }

    private func fail(_ id: Int, _ reason: String) {
        lock.lock()
        let request = pending.removeValue(forKey: id)
        lock.unlock()
        guard let request else { return }
        write(["cancel": .number(Double(id))])
        request.continuation.resume(throwing: RemoteError(reason))
    }

    public func watchTask(_ taskId: String, packet: @escaping @Sendable (JSON) -> Void, end: @escaping @Sendable (String) -> Void) -> Subscription {
        let subscription = UUID().uuidString.lowercased()
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            subscriptions[subscription] = Watch(packet: packet, end: end)
            sequence += 1
            return sequence
        }()
        write(["id": .number(Double(id)), "op": "taskWatch", "params": ["taskId": .string(taskId), "subscription": .string(subscription)]])
        return Subscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let existed = self.subscriptions.removeValue(forKey: subscription) != nil
            self.lock.unlock()
            if existed { self.write(["cancel": .string("sub:" + subscription)]) }
        }
    }

    private func shutdown(_ reason: String) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let requests = pending; pending = [:]
        let watches = subscriptions; subscriptions = [:]
        let open = streams; streams = [:]
        let sending = uploads; uploads = [:]
        lock.unlock()
        for stream in open.values { stream.end(reason) }
        for upload in sending.values { upload.update { $0.failure = reason } }
        for request in requests.values { request.continuation.resume(throwing: RemoteError(reason)) }
        for watch in watches.values { watch.end(reason) }
        onClosed?()
    }

    public func close() {
        lock.lock(); let process = child; lock.unlock()
        process?.kill()
        shutdown("SSH 通道已关闭")
    }
}

/// Owns one channel per server and restarts it on the next request after it closes.
public final class AgentClient: @unchecked Sendable {
    private let lock = NSLock()
    private struct ChannelEntry {
        let identity: UUID
        let task: Task<AgentChannel, Error>
    }
    private var channels: [String: ChannelEntry] = [:]
    public let launcher: RemoteLauncher
    public let resources: ServerResources
    public var onFileChange: (@Sendable (ConnectionConfig, [String]) -> Void)?

    public init(launcher: RemoteLauncher, resources: ServerResources) { self.launcher = launcher; self.resources = resources }

    public func channel(_ config: ConnectionConfig) async throws -> AgentChannel {
        let key = config.key
        let task = lock.withLock { () -> Task<AgentChannel, Error> in
            if let existing = channels[key] { return existing.task }
            let identity = UUID()
            let task = Task<AgentChannel, Error> { [weak self] in
                guard let self else { throw RemoteError("客户端已关闭") }
                let channel = AgentChannel(launcher: self.launcher, config: config, resources: self.resources)
                channel.onFileChange = { [weak self] directories in self?.onFileChange?(config, directories) }
                channel.onClosed = { [weak self] in self?.forget(key, identity: identity) }
                do { try await channel.start(); return channel }
                catch { self.forget(key, identity: identity); throw error }
            }
            channels[key] = ChannelEntry(identity: identity, task: task)
            return task
        }
        return try await task.value
    }

    private func forget(_ key: String, identity: UUID) {
        lock.withLock {
            // An old channel's delayed EOF must not evict the already reconnected channel.
            if channels[key]?.identity == identity { channels[key] = nil }
        }
    }

    public func call(_ config: ConnectionConfig, _ op: String, _ params: JSON, timeout: TimeInterval = 60) async throws -> JSON {
        try await channel(config).call(op, params, timeout: timeout)
    }

    public func info(_ config: ConnectionConfig) async throws -> ServerInfo {
        guard let info = try await channel(config).info else { throw RemoteError("远端代理未就绪") }
        return info
    }

    public func close(_ config: ConnectionConfig) {
        let task = lock.withLock { channels.removeValue(forKey: config.key)?.task }
        guard let task else { return }
        Task { (try? await task.value)?.close() }
    }
}
