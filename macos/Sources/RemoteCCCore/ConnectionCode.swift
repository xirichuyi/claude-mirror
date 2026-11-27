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

    /// The bytes of `known` plus any of `lines` it does not have yet. Lines that are not UTF-8 are kept as they are.
    public static func addingKnownHosts(_ known: Data, lines: [String]) -> Data {
        let existing = Set(known.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) })
        let missing = lines.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return known }
        var result = known
        if let last = result.last, last != 0x0A { result.append(0x0A) }
        result.append(Data((missing.joined(separator: "\n") + "\n").utf8))
        return result
    }

    public static func removingKnownHosts(_ known: Data, lines: [String]) -> Data {
        let drop = Set(lines)
        return Data(known.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !drop.contains(String(decoding: $0, as: UTF8.self)) }.joined(separator: [0x0A]))
    }

    /// Keys known_hosts already pins for this server, found the way OpenSSH looks them up (hashed entries included).
    static func pinnedKeys(_ pattern: String, path: String, keygen: String) -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: keygen)
        process.arguments = ["-F", pattern, "-f", path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            var fields = line.split(separator: " ").map(String.init)
            if fields.first?.hasPrefix("@") == true { fields.removeFirst() }
            return line.hasPrefix("#") || fields.count < 3 ? nil : fields[1] + " " + fields[2]
        }
    }

    /// Adds the code's host keys to known_hosts and returns the lines added, so a failed import can take them back.
    /// A server known_hosts already pins to other keys is refused rather than given a second identity.
    public static func trust(_ code: ConnectionCode, knownHosts path: String = NSHomeDirectory() + "/.ssh/known_hosts",
                             keygen: String = "/usr/bin/ssh-keygen") throws -> [String] {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pinned = pinnedKeys(code.port == 22 ? code.host : "[\(code.host)]:\(code.port)", path: path, keygen: keygen)
        guard pinned.isEmpty || pinned.contains(where: code.hostKeys.contains) else { throw RemoteError("主机指纹已变化，已拒绝连接") }
        let known = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let updated = addingKnownHosts(known, lines: code.knownHostsLines)
        guard updated != known else { return [] }
        try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let existing = Set(known.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) })
        return code.knownHostsLines.filter { !existing.contains($0) }
    }

    public static func untrust(_ lines: [String], knownHosts path: String = NSHomeDirectory() + "/.ssh/known_hosts") {
        guard !lines.isEmpty, let known = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let updated = removingKnownHosts(known, lines: lines)
        if updated != known { try? updated.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    /// Swaps the invitation key for `publicKey` in one step, and only while the invitation is still there,
    /// so a code that two people try at once gives access to one of them.
    public static func claimScript(publicKey: String) -> String {
        [
            "umask 077",
            "F=\"$HOME/.ssh/authorized_keys\"",
            "K=\(shellQuote(publicKey + " claude-mirror"))",
            "mkdir \"$F.lock\" 2>/dev/null || exit 1",
            "trap 'rmdir \"$F.lock\"' EXIT",
            "grep -q -- ' \(inviteComment)$' \"$F\" 2>/dev/null || { echo __RCC_USED__; exit 1; }",
            "{ grep -v -- ' \(inviteComment)$' \"$F\"; [ \"$?\" -le 1 ]; } > \"$F.new\" || exit 1",
            "grep -qxF -- \"$K\" \"$F.new\" || printf '%s\\n' \"$K\" >> \"$F.new\" || exit 1",
            "mv -f \"$F.new\" \"$F\" && chmod 600 \"$F\" || exit 1",
            "echo __RCC_CLAIMED__",
        ].joined(separator: "\n")
    }
}
