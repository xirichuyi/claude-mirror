import Foundation

/// The server-side end of a reverse connection to this Mac, or why it is unavailable.
public struct ReverseAccess: Sendable, Equatable {
    public var socketPath: String?
    /// ssh_config written on the server; `ssh -F <configPath> <name>` reaches this Mac.
    public var configPath: String?
    public var name: String
    public var error: String
    public init(socketPath: String? = nil, configPath: String? = nil, name: String = "", error: String = "") {
        self.socketPath = socketPath; self.configPath = configPath; self.name = name; self.error = error
    }
    public var command: String? { configPath.map { "ssh -F " + shellQuote($0) + " " + name } }
}

/// Everything reverse access needs besides the SSH master itself. Kept free of state so it is testable.
public enum ReverseSetup {
    public static let directory = ".claude-mirror/reverse"
    static let keyComment = "claude-mirror-reverse"
    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    private static func clean(_ text: String, limit: Int) -> String {
        String(String(String.UnicodeScalarView(text.unicodeScalars.map { safe.contains($0) ? $0 : "-" })).prefix(limit))
    }

    /// Socket and host alias on the server, derived from this Mac's name so several Macs do not collide.
    public static func socketName(hostName: String = ProcessInfo.processInfo.hostName) -> String {
        var name = hostName
        if name.lowercased().hasSuffix(".local") { name.removeLast(6) }
        let cleaned = clean(name, limit: 48)
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "mac" : cleaned
    }

    /// Identifies this server's line in authorized_keys, so it can be replaced or revoked alone.
    public static func marker(_ config: ConnectionConfig) -> String {
        keyComment + ":" + String(String.UnicodeScalarView(config.key.unicodeScalars.map {
            safe.contains($0) || "@.".unicodeScalars.contains($0) ? $0 : "_"
        }))
    }

    /// This Mac's own ed25519 host key, so the server can pin it instead of trusting on first use.
    public static func localHostKey(path: String = "/etc/ssh/ssh_host_ed25519_key.pub") -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return validKey(text)
    }

    /// Returns "ssh-ed25519 <base64>" or nil; comments and anything else are dropped.
    static func validKey(_ text: String) -> String? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard parts.count >= 2, parts[0] == "ssh-ed25519",
              parts[1].count >= 60, parts[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+/=".unicodeScalars.contains($0) }),
              parts[1].allSatisfy(\.isASCII) else { return nil }
        return "ssh-ed25519 " + parts[1]
    }

    /// Prepares the server: private directory, a dedicated key, the pinned host key and an ssh_config
    /// with connection reuse. Prints markers so login banners cannot be mistaken for output.
    public static func remoteScript(name: String, user: String, hostKey: String?) -> String {
        let pin = hostKey.map { "printf '%s\\n' " + shellQuote(name + " " + $0) + " > \"$D/\(name).known_hosts\" || exit 1" }
            ?? ": > \"$D/\(name).known_hosts\""
        return [
            "umask 077",
            "D=\"$HOME/\(directory)\"",
            "mkdir -p \"$D\" && chmod 700 \"$HOME/.claude-mirror\" \"$D\" || exit 1",
            "command -v socat >/dev/null 2>&1 || { echo __RCC_NO_SOCAT__; exit 0; }",
            "rm -f \"$D/\(name).sock\"",
            "[ -f \"$D/id_ed25519\" ] || ssh-keygen -q -t ed25519 -N '' -C \(keyComment) -f \"$D/id_ed25519\" >/dev/null || exit 1",
            pin,
            "cat > \"$D/\(name).config\" <<RCC_EOF || exit 1",
            "Host \(name)",
            "  User \(user)",
            "  ProxyCommand socat - UNIX-CONNECT:$D/\(name).sock",
            "  HostKeyAlias \(name)",
            "  UserKnownHostsFile $D/\(name).known_hosts",
            "  StrictHostKeyChecking \(hostKey == nil ? "accept-new" : "yes")",
            "  IdentityFile $D/id_ed25519",
            "  IdentitiesOnly yes",
            "  ControlMaster auto",
            "  ControlPath $D/cm-%C",
            "  ControlPersist 10m",
            "  ServerAliveInterval 15",
            "  ServerAliveCountMax 3",
            "RCC_EOF",
            "echo \"__RCC_HOME__=$HOME\"",
            "echo \"__RCC_KEY__=$(cat \"$D/id_ed25519.pub\")\""
        ].joined(separator: "\n")
    }

    /// Closes any session the server opened to this Mac and removes its socket.
    public static func remoteRevokeScript(name: String) -> String {
        let directory = "\"$HOME/\(Self.directory)\""
        return "ssh -F \(directory)/\(name).config -O exit \(name) >/dev/null 2>&1; rm -f \(directory)/\(name).sock"
    }

    public struct RemoteInfo: Equatable { public var home: String; public var publicKey: String }

    public static func parse(_ output: String) -> RemoteInfo? {
        var home: String?, key: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("__RCC_HOME__=") { home = String(line.dropFirst("__RCC_HOME__=".count)) }
            if line.hasPrefix("__RCC_KEY__=") { key = validKey(String(line.dropFirst("__RCC_KEY__=".count))) }
        }
        guard let home, home.hasPrefix("/"), let key else { return nil }
        return RemoteInfo(home: home, publicKey: key)
    }

    public static func socketPath(home: String, name: String) -> String { home + "/" + directory + "/" + name + ".sock" }
    public static func configPath(home: String, name: String) -> String { home + "/" + directory + "/" + name + ".config" }

    /// The server's key may only log in through the tunnel (it arrives from 127.0.0.1) and cannot forward an agent.
    public static func authorizedLine(publicKey: String, marker: String) -> String {
        "from=\"127.0.0.1,::1\",no-agent-forwarding,no-X11-forwarding " + publicKey + " " + marker
    }

    /// Replaces or removes only this server's line; everything else is kept byte for byte.
    public static func updatedAuthorizedKeys(_ text: String, marker: String, line: String?) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines.removeAll { $0.hasSuffix(" " + marker) }
        if let line { lines.append(line) }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func writeAuthorizedKeys(path: String, marker: String, line: String?) throws {
        let target = (path as NSString).resolvingSymlinksInPath
        let folder = (target as NSString).deletingLastPathComponent
        let manager = FileManager.default
        let existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        let updated = updatedAuthorizedKeys(existing, marker: marker, line: line)
        if updated == existing { return }
        if !manager.fileExists(atPath: folder) {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // sshd ignores keys in a group/world-writable file, so the replacement is created 0600 and renamed in.
        let temporary = folder + "/.authorized_keys.claude-mirror-" + UUID().uuidString
        guard manager.createFile(atPath: temporary, contents: Data(updated.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw RemoteError("无法写入 \(target)")
        }
        guard rename(temporary, target) == 0 else {
            try? manager.removeItem(atPath: temporary)
            throw RemoteError("无法更新 \(target)")
        }
    }
}
