import Foundation

public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Returns as soon as any bytes arrive, or nil at end of file. FileHandle.read(upToCount:)
/// may wait for the full count, which would hold back a single protocol line.
private func readAvailable(_ handle: FileHandle, limit: Int) -> Data? {
    var buffer = [UInt8](repeating: 0, count: limit)
    while true {
        let count = read(handle.fileDescriptor, &buffer, limit)
        if count > 0 { return Data(buffer[0..<count]) }
        if count < 0, errno == EINTR { continue }
        return nil
    }
}

/// A running remote command with non-blocking, ordered stdin writes.
public final class RemoteProcess: @unchecked Sendable {
    private let process: Process
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let writes = DispatchQueue(label: "remotecc.process.stdin")
    private let lock = NSLock()
    private var errorText = ""
    private let finished = DispatchGroup()
    private var exitContinuations: [CheckedContinuation<Int32, Never>] = []
    private var exitCode: Int32?

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        signal(SIGPIPE, SIG_IGN)
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        finished.enter()
        process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
        try process.run()
        let handle = stderr.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while let chunk = readAvailable(handle, limit: 8192) {
                guard let self else { return }
                self.lock.lock()
                self.errorText = String((self.errorText + String(decoding: chunk, as: UTF8.self)).suffix(8000))
                self.lock.unlock()
            }
        }
    }

    private func exited(_ code: Int32) {
        lock.lock()
        exitCode = code
        let waiting = exitContinuations
        exitContinuations = []
        lock.unlock()
        waiting.forEach { $0.resume(returning: code) }
        finished.leave()
    }

    public var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return errorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func write(_ data: Data) {
        let handle = stdin.fileHandleForWriting
        writes.async { try? handle.write(contentsOf: data) }
    }

    /// Await pipe capacity so large uploads cannot queue the entire file in RAM.
    public func writeAndWait(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let handle = stdin.fileHandleForWriting
                writes.async {
                    do { try handle.write(contentsOf: data); done.resume() }
                    catch { done.resume(throwing: error) }
                }
            }
        }, onCancel: { self.kill() })
    }

    public func closeInput() {
        let handle = stdin.fileHandleForWriting
        writes.async { try? handle.close() }
    }

    /// Blocks this thread reading stdout; `chunk` runs for each read, then `done`.
    public func readOutput(chunk: @escaping @Sendable (Data) -> Void, done: @escaping @Sendable () -> Void) {
        let handle = stdout.fileHandleForReading
        Thread.detachNewThread {
            while let data = readAvailable(handle, limit: 256 * 1024) { chunk(data) }
            done()
        }
    }

    public func kill() { if process.isRunning { process.terminate() } }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitCode { lock.unlock(); continuation.resume(returning: exitCode); return }
            exitContinuations.append(continuation)
            lock.unlock()
        }
    }
}

/// Starts commands on the server. SSH in production; `sh -c` in tests.
public protocol RemoteLauncher: AnyObject, Sendable {
    func spawn(_ config: ConnectionConfig, command: String) throws -> RemoteProcess
}

/// Splits a byte stream into lines without assuming chunks align with UTF-8 boundaries.
struct LineBuffer {
    private var pending = Data()
    mutating func append(_ data: Data, _ line: (Data) -> Void) {
        pending.append(data)
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 10) {
            line(pending[start..<newline])
            start = pending.index(after: newline)
        }
        if start != pending.startIndex { pending = Data(pending[start...]) }
    }
}

public enum ConnectionStatus: String, Sendable { case disconnected, connecting, connected, reconnecting, error }

public struct ConnectionState: Sendable, Equatable {
    public var status: ConnectionStatus
    public var error: String
    public init(status: ConnectionStatus = .disconnected, error: String = "") { self.status = status; self.error = error }
}

public struct Tunnel: Hashable, Sendable, Identifiable {
    public var localPort: Int
    public var remotePort: Int
    public var id: String { "\(localPort):\(remotePort)" }
    public init(localPort: Int, remotePort: Int) { self.localPort = localPort; self.remotePort = remotePort }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); if data.count < 65536 { data.append(chunk) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// System OpenSSH with one ControlMaster per server: reuses ~/.ssh/config, keys, agent and jump hosts.
public final class SSHConnections: RemoteLauncher, @unchecked Sendable {
    private struct Entry { var config: ConnectionConfig; var socket: String; var state = ConnectionState(); var tunnels: [Tunnel] = []; var reverse = ReverseAccess() }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var desired: [String: ConnectionConfig] = [:]
    private var attempts: [String: Int] = [:]
    private var inFlight = Set<String>()
    private var checking = Set<String>()
    private var monitor: Task<Void, Never>?
    private let directory: String
    private let executable: String
    private let askpassPath: String?
    /// Called on an arbitrary thread whenever a connection changes state.
    public var onState: (@Sendable (ConnectionConfig, ConnectionState) -> Void)?
    /// Called after an automatic reconnection, when subscriptions must be re-established.
    public var onRecovered: (@Sendable (ConnectionConfig) -> Void)?
    /// Called whenever the reverse connection to this Mac is opened, closed or fails.
    public var onReverse: (@Sendable (ConnectionConfig, ReverseAccess) -> Void)?
    /// Whether this Mac accepts SSH; replaceable in tests.
    public var localSSHAvailable: @Sendable () -> Bool = { SSHConnections.localPortOpen(22) }
    /// Where the server's dedicated key is authorized; replaceable in tests.
    public var authorizedKeysPath = NSHomeDirectory() + "/.ssh/authorized_keys"
    /// This Mac's host key, pinned on the server; replaceable in tests.
    public var localHostKey: @Sendable () -> String? = { ReverseSetup.localHostKey() }

    public init(executable: String = "/usr/bin/ssh", askpassPath: String? = nil) throws {
        self.executable = executable
        self.askpassPath = askpassPath
        // Unix socket paths are limited to about 100 bytes, so avoid the long macOS temp directory.
        directory = "/tmp/rcc-\(getuid())-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        monitor = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.checkConnections()
            }
        }
    }

    deinit { monitor?.cancel() }

    public static func authenticationArguments(_ config: ConnectionConfig) -> [String] {
        switch config.authentication ?? .automatic {
        case .automatic: return []
        case .password: return ["-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        case .keyFile:
            guard let file = config.identityFile else { return [] }
            return ["-i", file, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey"]
        }
    }

    private func portArguments(_ config: ConnectionConfig) -> [String] { config.port.map { ["-p", String($0)] } ?? [] }
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func reverseAccess(_ config: ConnectionConfig) -> ReverseAccess { withLock { entries[config.key]?.reverse ?? ReverseAccess() } }

    public static func localPortOpen(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    public func state(_ config: ConnectionConfig) -> ConnectionState { withLock { entries[config.key]?.state ?? ConnectionState() } }
    public func tunnels(_ config: ConnectionConfig) -> [Tunnel] { withLock { entries[config.key]?.tunnels ?? [] } }

    @discardableResult
    private func setState(_ config: ConnectionConfig, _ state: ConnectionState, socket: String) -> Bool {
        let current = withLock {
            guard desired[config.key] != nil, entries[config.key]?.socket == socket else { return false }
            entries[config.key]?.state = state
            return true
        }
        if current { onState?(config, state) }
        return current
    }

    private struct SSHCommandTimeout: LocalizedError {
        let seconds: UInt64
        var errorDescription: String? { "SSH 操作超时（\(seconds) 秒）" }
    }
    private final class DeadlineState: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false
        func expire() { lock.lock(); expired = true; lock.unlock() }
        var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    }

    private func runSSH(_ arguments: [String], timeout: UInt64, interactive: Bool = false, password: String? = nil) async throws {
        var environment = ProcessInfo.processInfo.environment
        if interactive, let askpassPath {
            environment["SSH_ASKPASS"] = askpassPath
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        }
        // Only the one-shot askpass helper receives this protected credential path.
        // Never persist credentials in ConnectionConfig or put them in process arguments.
        var credentialPath: String?
        defer { if let credentialPath { try? FileManager.default.removeItem(atPath: credentialPath) } }
        if interactive, let password {
            let path = directory + "/credential-" + UUID().uuidString
            guard FileManager.default.createFile(atPath: path, contents: Data(password.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw RemoteError("无法准备 SSH 身份验证")
            }
            credentialPath = path
            environment["MIRROR_SSH_CREDENTIAL_FILE"] = path
        }
        let child = try RemoteProcess(executable: executable, arguments: arguments, environment: environment)
        child.closeInput()
        let deadline = DeadlineState()
        let timer = Task {
            try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            deadline.expire(); child.kill()
        }
        let code = await child.waitForExit()
        timer.cancel()
        if deadline.didExpire { throw SSHCommandTimeout(seconds: timeout) }
        if code != 0 { throw RemoteError(child.stderrText.isEmpty ? "SSH 连接失败（\(code)）" : child.stderrText) }
    }

    public func connect(_ input: ConnectionConfig, password: String? = nil) async throws {
        try await connect(input, requiringDesired: false, password: password)
    }

    private func connect(_ input: ConnectionConfig, requiringDesired: Bool, password: String? = nil) async throws {
        let config = try input.validated()
        let key = config.key
        let proceed: Bool = withLock {
            if requiringDesired && desired[key] == nil { return false }
            desired[key] = config
            if entries[key]?.state.status == .connected || inFlight.contains(key) { return false }
            inFlight.insert(key)
            let previous = entries[key]
            entries[key] = Entry(config: config, socket: directory + "/" + UUID().uuidString.prefix(12), state: ConnectionState(status: attempts[key] != nil ? .reconnecting : .connecting), tunnels: previous?.tunnels ?? [])
            return true
        }
        guard proceed else {
            // Another caller is connecting; wait for its outcome rather than reporting success early.
            while withLock({ inFlight.contains(key) }) { try await Task.sleep(nanoseconds: 50_000_000) }
            if state(config).status != .connected { throw RemoteError(state(config).error.isEmpty ? "SSH 连接失败" : state(config).error) }
            return
        }
        guard let socket = withLock({ entries[key]?.socket }) else {
            _ = withLock { inFlight.remove(key) }; throw CancellationError()
        }
        defer { _ = withLock { inFlight.remove(key) } }
        onState?(config, state(config))
        do {
            let interactive = !requiringDesired && askpassPath != nil
            try await runSSH(["-M", "-N", "-f", "-S", socket, "-o", "ControlPersist=no",
                              "-o", "BatchMode=\(interactive ? "no" : "yes")", "-o", "StrictHostKeyChecking=ask", "-o", "ConnectTimeout=15",
                              "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "Compression=yes"]
                             + Self.authenticationArguments(config) + portArguments(config) + [config.host],
                             timeout: interactive ? 180 : 20, interactive: interactive,
                             password: config.authentication == .password ? password : nil)
            guard setState(config, ConnectionState(status: .connected), socket: socket) else {
                try? await runSSH(["-S", socket, "-O", "exit"] + portArguments(config) + [config.host], timeout: 5)
                throw CancellationError()
            }
            await applyReverse(config, socket: socket)
            let recovered = withLock { attempts.removeValue(forKey: key) != nil && desired[key] != nil }
            if recovered {
                for tunnel in tunnels(config) { try? await forward(config, tunnel) }
                onRecovered?(config)
            }
        } catch {
            if setState(config, ConnectionState(status: .error, error: error.localizedDescription), socket: socket) {
                if requiringDesired { scheduleReconnect(config) }
            }
            throw error
        }
    }

    private func scheduleReconnect(_ config: ConnectionConfig) {
        let attempt: Int? = withLock {
            guard desired[config.key] != nil else { return nil }
            let next = attempts[config.key] ?? 0
            attempts[config.key] = next + 1
            return next
        }
        guard let attempt else { return }
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5)))) * Double.random(in: 0.8...1.2)
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // The latest settings win: a toggle made while offline must survive the reconnect.
            guard let self, let current = self.withLock({ self.desired[config.key] }) else { return }
            try? await self.connect(current, requiringDesired: true)
        }
    }

    public func spawn(_ config: ConnectionConfig, command: String) throws -> RemoteProcess {
        let (socket, status) = withLock { (entries[config.key]?.socket, entries[config.key]?.state.status) }
        guard let socket, status == .connected else { throw RemoteError("请先连接 SSH 服务器") }
        // ProxyCommand=false stops a dead master from silently opening a new connection.
        return try RemoteProcess(executable: executable, arguments: ["-T", "-S", socket, "-o", "BatchMode=yes", "-o", "ProxyCommand=false"] + portArguments(config) + [config.host, command])
    }

    /// Probe the remote endpoint, not just the local ControlMaster socket.
    /// Machines are checked concurrently so an unreachable host cannot delay another.
    public func checkConnections() async {
        let connected = withLock {
            let candidates = entries.values.filter { $0.state.status == .connected && !checking.contains($0.config.key) }
            candidates.forEach { checking.insert($0.config.key) }
            return candidates
        }
        await withTaskGroup(of: Void.self) { group in
            for entry in connected {
                group.addTask { [self] in
                    defer { _ = withLock { checking.remove(entry.config.key) } }
                    do {
                        try await runSSH(["-T", "-S", entry.socket, "-o", "BatchMode=yes", "-o", "ProxyCommand=false"] + portArguments(entry.config) + [entry.config.host, "true"], timeout: 8)
                        if !state(entry.config).error.isEmpty {
                            _ = setState(entry.config, ConnectionState(status: .connected), socket: entry.socket)
                        }
                    } catch {
                        // A delayed probe is not proof that the shared transport is dead.
                        // Killing a live master here also truncates unrelated downloads.
                        // OpenSSH's server-alive checks handle an actually unreachable peer.
                        if error is SSHCommandTimeout,
                           (try? await runSSH(["-S", entry.socket, "-O", "check"] + portArguments(entry.config) + [entry.config.host], timeout: 2)) != nil {
                            _ = setState(entry.config, ConnectionState(status: .connected, error: "网络响应较慢，正在检查连接"), socket: entry.socket)
                            return
                        }
                        guard setState(entry.config, ConnectionState(status: .error, error: "SSH 连接已断开"), socket: entry.socket) else { return }
                        // A live but stale master would otherwise prevent a fresh connection.
                        try? await runSSH(["-S", entry.socket, "-O", "exit"] + portArguments(entry.config) + [entry.config.host], timeout: 5)
                        scheduleReconnect(entry.config)
                    }
                }
            }
        }
    }

    /// A real network-path change or wake should not wait behind an old backoff timer.
    /// Only reconnect machines the user still wants connected.
    public func networkBecameAvailable() async {
        await checkConnections()
        let configs = withLock {
            desired.values.filter { entries[$0.key]?.state.status != .connected && !inFlight.contains($0.key) }
        }
        await withTaskGroup(of: Void.self) { group in
            for config in configs { group.addTask { try? await self.connect(config, requiringDesired: true) } }
        }
    }

    private func runRemote(_ config: ConnectionConfig, socket: String, command: String, timeout: UInt64) async throws -> String {
        let child = try RemoteProcess(executable: executable, arguments: ["-T", "-S", socket, "-o", "BatchMode=yes", "-o", "ProxyCommand=false"] + portArguments(config) + [config.host, command])
        child.closeInput()
        let output = OutputBuffer()
        let reading = Task { await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in child.readOutput(chunk: { output.append($0) }, done: { done.resume() }) } }
        let deadline = DeadlineState()
        let timer = Task {
            try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            deadline.expire(); child.kill()
        }
        let code = await child.waitForExit()
        timer.cancel()
        await reading.value
        if deadline.didExpire { throw SSHCommandTimeout(seconds: timeout) }
        if code != 0 { throw RemoteError(child.stderrText.isEmpty ? "远端命令失败（\(code)）" : child.stderrText) }
        return output.text
    }

    /// Binds a private Unix socket on the server to this Mac's sshd, over the existing master,
    /// and authorizes a key that only works through that socket. A stale socket from a dropped
    /// connection is removed first, so reconnects always rebind.
    private func applyReverse(_ config: ConnectionConfig, socket: String) async {
        guard config.reverseAccess == true else { return }
        let name = ReverseSetup.socketName()
        var result = ReverseAccess(name: name)
        if !localSSHAvailable() {
            result.error = "本机未开启远程登录（系统设置 → 通用 → 共享 → 远程登录）"
        } else {
            do {
                let user = NSUserName()
                guard !user.isEmpty, user.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }) else {
                    throw RemoteError("本机用户名包含不支持的字符")
                }
                let output = try await runRemote(config, socket: socket, command: ReverseSetup.remoteScript(name: name, user: user, hostKey: localHostKey()), timeout: 30)
                if output.contains("__RCC_NO_SOCAT__") { throw RemoteError("服务器缺少 socat，请先安装（例如 apt install socat）") }
                guard let info = ReverseSetup.parse(output) else { throw RemoteError("服务器返回的信息不完整") }
                let marker = ReverseSetup.marker(config)
                try ReverseSetup.writeAuthorizedKeys(path: authorizedKeysPath, marker: marker, line: ReverseSetup.authorizedLine(publicKey: info.publicKey, marker: marker))
                let path = ReverseSetup.socketPath(home: info.home, name: name)
                try await runSSH(["-S", socket, "-O", "forward", "-R", path + ":127.0.0.1:22", "-o", "ExitOnForwardFailure=yes"] + portArguments(config) + [config.host], timeout: 10)
                result.socketPath = path
                result.configPath = ReverseSetup.configPath(home: info.home, name: name)
            } catch { result.error = "反向连接未开启：" + error.localizedDescription }
        }
        let current = withLock {
            guard entries[config.key]?.socket == socket, entries[config.key]?.config.reverseAccess == true else { return false }
            entries[config.key]?.reverse = result
            return true
        }
        if current { onReverse?(config, result) }
    }

    /// Turns reverse access on or off now, and for every later reconnect.
    /// Turning it off revokes the key locally first, so it takes effect even while offline.
    public func setReverseAccess(_ input: ConnectionConfig, enabled: Bool) async {
        let value: Bool? = enabled ? true : nil
        let entry: Entry? = withLock {
            desired[input.key]?.reverseAccess = value
            entries[input.key]?.config.reverseAccess = value
            return entries[input.key]
        }
        if !enabled {
            do { try ReverseSetup.writeAuthorizedKeys(path: authorizedKeysPath, marker: ReverseSetup.marker(input), line: nil) }
            catch { onReverse?(input, ReverseAccess(error: "撤销授权失败：" + error.localizedDescription)); return }
        }
        guard let entry, entry.state.status == .connected else {
            if !enabled { onReverse?(input, ReverseAccess()) }
            return
        }
        if enabled { await applyReverse(entry.config, socket: entry.socket); return }
        if let path = entry.reverse.socketPath {
            try? await runSSH(["-S", entry.socket, "-O", "cancel", "-R", path + ":127.0.0.1:22"] + portArguments(entry.config) + [entry.config.host], timeout: 10)
        }
        _ = try? await runRemote(entry.config, socket: entry.socket, command: ReverseSetup.remoteRevokeScript(name: entry.reverse.name.isEmpty ? ReverseSetup.socketName() : entry.reverse.name), timeout: 10)
        withLock { if entries[input.key]?.socket == entry.socket { entries[input.key]?.reverse = ReverseAccess() } }
        onReverse?(entry.config, ReverseAccess())
    }

    public func forward(_ config: ConnectionConfig, _ tunnel: Tunnel, remove: Bool = false) async throws {
        guard let socket = withLock({ entries[config.key]?.socket }), state(config).status == .connected else { throw RemoteError("请先连接 SSH") }
        guard (1...65535).contains(tunnel.localPort), (1...65535).contains(tunnel.remotePort) else { throw RemoteError("端口应为 1–65535") }
        try await runSSH(["-S", socket, "-O", remove ? "cancel" : "forward", "-L", "127.0.0.1:\(tunnel.localPort):127.0.0.1:\(tunnel.remotePort)", "-o", "ExitOnForwardFailure=yes"] + portArguments(config) + [config.host], timeout: 10)
        withLock {
            var list = entries[config.key]?.tunnels ?? []
            list.removeAll { $0 == tunnel }
            if !remove { list.append(tunnel) }
            entries[config.key]?.tunnels = list
        }
    }

    public func disconnect(_ config: ConnectionConfig) async {
        let entry: Entry? = withLock {
            desired[config.key] = nil; attempts[config.key] = nil
            return entries.removeValue(forKey: config.key)
        }
        if let entry { try? await runSSH(["-S", entry.socket, "-O", "exit"] + portArguments(config) + [config.host], timeout: 5) }
        onState?(config, ConnectionState())
    }

    public func closeAll() async {
        let all = withLock { entries.values.map(\.config) }
        for config in all { await disconnect(config) }
        monitor?.cancel()
        try? FileManager.default.removeItem(atPath: directory)
    }
}
