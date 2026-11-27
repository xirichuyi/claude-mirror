import Foundation

/// A one-use code from the server panel or `install-claude-remote.sh --invite`: where to connect, as whom, and with which key.
public struct ConnectionCode: Equatable, Sendable {
    public static let prefix = "cm1."
    public static let inviteComment = "claude-mirror-invite"
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var hostKeys: [String]
    public var privateKey: String

    public static func looksLike(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) }

    public static func parse(_ text: String) throws -> ConnectionCode {
        let invalid = RemoteError("连接码无效")
        var body = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard body.hasPrefix(prefix) else { throw invalid }
        body = String(body.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body), let decoded = String(data: data, encoding: .utf8) else { throw invalid }
        var lines = decoded.components(separatedBy: "\n")
        guard lines.first == "claude-mirror 1" else { throw RemoteError("连接码版本不支持，请更新 App") }
        lines.removeFirst()
        var fields: [String: String] = [:]
        var hostKeys: [String] = []
        var keyLines: [String] = []
        for line in lines {
            if !keyLines.isEmpty || line.hasPrefix("-----BEGIN ") { keyLines.append(line); continue }
            guard let space = line.firstIndex(of: " ") else { continue }
            let field = String(line[..<space]), value = String(line[line.index(after: space)...])
            if field == "hostkey" { hostKeys.append(value) } else { fields[field] = value }
        }
        let privateKey = keyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let host = fields["host"], !host.isEmpty, !host.hasPrefix("-"), host.allSatisfy({ $0.isLetter || $0.isNumber || ".:-_".contains($0) }),
              let user = fields["user"], !user.isEmpty, !user.hasPrefix("-"), user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
              let port = Int(fields["port"] ?? "22"), (1...65535).contains(port),
              privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"), privateKey.contains("-----END OPENSSH PRIVATE KEY-----"),
              !hostKeys.isEmpty, hostKeys.allSatisfy(validHostKey)
        else { throw invalid }
        return ConnectionCode(name: fields["name"] ?? host, host: host, port: port, user: user, hostKeys: hostKeys, privateKey: privateKey)
    }

    static func validHostKey(_ text: String) -> Bool {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        let types = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
        return parts.count == 2 && types.contains(String(parts[0])) && parts[1].count >= 60
            && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }
    }

    public var destination: String { user + "@" + host }

    /// The lines OpenSSH expects in known_hosts for this server, so the first connection asks nothing.
    public var knownHostsLines: [String] {
        let pattern = port == 22 ? host : "[\(host)]:\(port)"
        return hostKeys.map { pattern + " " + $0 }
    }

    /// Lines of `known` plus any of `lines` it does not have yet.
    public static func addingKnownHosts(_ known: String, lines: [String]) -> String {
        let existing = Set(known.components(separatedBy: "\n"))
        let missing = lines.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return known }
        let base = known.isEmpty || known.hasSuffix("\n") ? known : known + "\n"
        return base + missing.joined(separator: "\n") + "\n"
    }

    public static func trust(_ code: ConnectionCode, knownHosts path: String = NSHomeDirectory() + "/.ssh/known_hosts") throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let known = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = addingKnownHosts(known, lines: code.knownHostsLines)
        guard updated != known else { return }
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Run after the app's own key is known to work: the invitation key stops working.
    public static let dropInviteScript = [
        "F=\"$HOME/.ssh/authorized_keys\"",
        "[ -f \"$F\" ] || exit 1",
        "umask 077",
        "grep -v -- ' \(inviteComment)$' \"$F\" > \"$F.new\"; mv -f \"$F.new\" \"$F\" && chmod 600 \"$F\" || exit 1",
        "echo __RCC_CLAIMED__",
    ].joined(separator: "\n")
}
