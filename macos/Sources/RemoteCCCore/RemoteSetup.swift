import Foundation

/// Why the remote agent could not start. The app turns these into setup guidance instead of a bare error.
public enum RemoteSetupError: LocalizedError, Equatable, Sendable {
    case nodeMissing
    case nodeOutdated(String)
    public var errorDescription: String? {
        switch self {
        case .nodeMissing: return "服务器上没有 Node.js（需要 18.14 或更新版本）。"
        case .nodeOutdated(let version): return "服务器上的 Node.js \(version) 太旧，需要 18.14 或更新版本。"
        }
    }
}

public enum ClaudeAuthState: String, Sendable, Equatable { case loggedIn, loggedOut, unknown }

/// Result of the agent's `claudeStatus` operation.
public struct ClaudeStatus: Sendable, Equatable {
    public var claude: String?
    public var auth: ClaudeAuthState
    public var loginCommand: String?
    public init(claude: String?, auth: ClaudeAuthState, loginCommand: String? = nil) {
        self.claude = claude; self.auth = auth; self.loginCommand = loginCommand
    }
    public init(json: JSON) {
        claude = json["claude"]?.string
        auth = json["auth"]?.string.flatMap(ClaudeAuthState.init(rawValue:)) ?? .unknown
        loginCommand = json["loginCommand"]?.string
    }
}

/// One thing standing between a new user and a working conversation, with the fix the app can offer.
public struct HealthIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case node, claude, login, persistence }
    public enum Action: Equatable, Sendable {
        /// Run the bundled installer over this SSH connection.
        case install
        /// Open a terminal on the server running this command.
        case login(command: String)
        /// Commands that need the user (or an administrator) on the server.
        case copy(command: String)
    }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var action: Action?
    /// Conversations cannot work until this is fixed.
    public var blocking: Bool
    public var id: String { kind.rawValue }
}

public enum MachineHealth {
    /// Builds the checklist from what connecting learned. `status` is nil until Claude has been checked.
    public static func issues(startError: Error?, info: ServerInfo?, status: ClaudeStatus?) -> [HealthIssue] {
        var result: [HealthIssue] = []
        if let setup = startError as? RemoteSetupError {
            let detail = "镜像 Claude 在服务器上运行一个小程序来管理对话，它需要 Node.js。一键安装会把官方 Node.js 装到你的用户目录，不需要管理员权限，也不影响系统里已有的版本。"
            switch setup {
            case .nodeMissing: result.append(HealthIssue(kind: .node, title: "服务器缺少 Node.js", detail: detail, action: .install, blocking: true))
            case .nodeOutdated(let version): result.append(HealthIssue(kind: .node, title: "服务器的 Node.js \(version) 太旧", detail: detail, action: .install, blocking: true))
            }
            return result
        }
        guard let info else { return result }
        let claudePath = status.map(\.claude) ?? info.claude
        if claudePath == nil {
            result.append(HealthIssue(kind: .claude, title: "服务器还没有安装 Claude Code",
                                      detail: "一键安装会使用 Anthropic 官方安装程序，把 Claude Code 装到你的用户目录。",
                                      action: .install, blocking: true))
        } else if let status, status.auth == .loggedOut {
            let command = status.loginCommand ?? "claude auth login"
            result.append(HealthIssue(kind: .login, title: "服务器上的 Claude Code 还没有登录",
                                      detail: "点击“在终端登录”，按提示用浏览器完成授权；登录信息只保存在服务器上。完成后点“重新检查”。",
                                      action: .login(command: command), blocking: true))
        }
        if let warning = info.persistenceWarning {
            result.append(HealthIssue(kind: .persistence, title: "断开连接后回复会中断", detail: warning,
                                      action: .copy(command: "loginctl enable-linger"), blocking: false))
        }
        return result
    }
}

/// Turns OpenSSH's terse failures into what a new user can act on. Unknown messages pass through.
public enum ConnectionAdvice {
    private static let rules: [(patterns: [String], advice: String)] = [
        (["permission denied", "authentication failed"], "服务器拒绝了登录：用户名、密码或密钥不正确。请检查用户名，或在“登录方式”里改用密码。"),
        (["too many authentication failures"], "本机尝试了太多把密钥，被服务器拒绝。请在“登录方式”里选择具体的私钥文件，或改用密码。"),
        (["could not resolve hostname", "nodename nor servname", "name or service not known", "temporary failure in name resolution"], "找不到这个服务器地址。请检查地址是否拼写正确，或确认网络、VPN 已连接。"),
        (["connection refused"], "服务器拒绝连接：SSH 服务可能没有运行，或端口不对（通常是 22）。"),
        (["operation timed out", "connection timed out", "ssh 操作超时"], "连接超时：服务器可能已关机，或被防火墙、网络拦截。请确认这台电脑能访问它。"),
        (["no route to host", "network is unreachable", "network unreachable"], "网络不通：请检查网络连接或 VPN。"),
        (["host key verification failed", "remote host identification has changed"], "服务器的身份指纹和上次不同。如果服务器刚重装过，请在终端运行 ssh-keygen -R 加上服务器地址，然后重试；否则请先确认没有连到冒充的服务器。"),
        (["connection closed by", "kex_exchange_identification", "connection reset"], "服务器在登录前断开了连接：可能限制了来源 IP，或 SSH 服务异常。"),
    ]

    public static func explain(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("原始信息：") else { return trimmed }
        let lower = trimmed.lowercased()
        guard let rule = rules.first(where: { rule in rule.patterns.contains { pattern in lower.contains(pattern) } }) else { return trimmed }
        let detail = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
        return rule.advice + "\n原始信息：" + detail
    }
}

/// Replaces password logins with a dedicated key. Nothing else in ~/.ssh is touched.
public enum LoginKeySetup {
    public static var defaultKeyPath: String { NSHomeDirectory() + "/.ssh/claude_mirror_ed25519" }

    /// Creates the key once and returns its public half as "ssh-ed25519 <base64>".
    public static func ensureKey(at path: String = defaultKeyPath, keygen: String = "/usr/bin/ssh-keygen") throws -> String {
        let manager = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        if !manager.fileExists(atPath: folder) {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !manager.fileExists(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: keygen)
            process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "claude-mirror", "-f", path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RemoteError("无法生成登录密钥") }
        }
        guard let text = try? String(contentsOfFile: path + ".pub", encoding: .utf8), let key = ReverseSetup.validKey(text) else {
            throw RemoteError("登录密钥 \(path).pub 无法读取")
        }
        return key
    }

    /// Adds the key to the server's authorized_keys once, keeping every existing line.
    public static func authorizeScript(publicKey: String) -> String {
        let line = publicKey + " claude-mirror"
        return [
            "umask 077",
            "F=\"$HOME/.ssh/authorized_keys\"",
            "mkdir -p \"$HOME/.ssh\" && chmod 700 \"$HOME/.ssh\" && touch \"$F\" && chmod 600 \"$F\" || exit 1",
            "K=\(shellQuote(line))",
            // A final line without a newline would otherwise merge with the appended key.
            "if [ -s \"$F\" ] && [ -n \"$(tail -c 1 \"$F\")\" ]; then echo >> \"$F\"; fi",
            "grep -qxF \"$K\" \"$F\" || printf '%s\\n' \"$K\" >> \"$F\" || exit 1",
            "echo __RCC_KEY_OK__",
        ].joined(separator: "\n")
    }
}

/// Runs the bundled install-claude-remote.sh over an existing SSH connection, streaming its output.
public enum RemoteInstaller {
    public static let command = "sh -c " + shellQuote("command -v bash >/dev/null 2>&1 || { echo '服务器缺少 bash，无法自动安装。'; exit 1; }; exec bash -s 2>&1")

    /// Returns the installer's exit status: 0 ready, 3 Node.js could not be installed.
    public static func run(launcher: RemoteLauncher, config: ConnectionConfig, script: Data,
                           output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = try launcher.spawn(config, command: command)
        return await withTaskCancellationHandler {
            let reading = Task {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let buffer = LineCollector()
                    process.readOutput(chunk: { data in
                        for line in buffer.append(data) { output(line) }
                    }, done: {
                        if let rest = buffer.finish() { output(rest) }
                        done.resume()
                    })
                }
            }
            process.write(script)
            process.closeInput()
            let code = await process.waitForExit()
            await reading.value
            return code
        } onCancel: { process.kill() }
    }

    public static func summary(_ code: Int32) -> String {
        switch code {
        case 0: return "安装完成，正在重新检查服务器…"
        case 3: return "Claude Code 已就绪，但 Node.js 没能自动安装。请按上面的提示用系统包管理器安装 Node.js 18.14 或更新版本。"
        default: return "安装没有完成（退出码 \(code)）。请查看上面的输出；常见原因是服务器无法访问外网。"
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = LineBuffer()
    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        buffer.append(data) { lines.append(String(decoding: $0, as: UTF8.self)) }
        return lines
    }
    func finish() -> String? {
        lock.lock(); defer { lock.unlock() }
        var rest: String?
        buffer.append(Data([10])) { line in if !line.isEmpty { rest = String(decoding: line, as: UTF8.self) } }
        return rest
    }
}
