import XCTest
@testable import RemoteCCCore

final class SSHConfigurationTests: XCTestCase {
    func testExistingProfilesDecodeWithoutMigration() throws {
        let data = Data(#"{"host":"dev","directory":"~"}"#.utf8)
        let config = try JSONDecoder().decode(ConnectionConfig.self, from: data)
        XCTAssertEqual(config.displayName, "dev")
        XCTAssertNil(config.authentication)
        XCTAssertEqual(SSHConnections.authenticationArguments(config), [])
    }

    func testRenameDoesNotChangeConnectionIdentity() throws {
        let original = ConnectionConfig(host: "user@example.com", port: 2222)
        var renamed = original
        renamed.name = "  开发服务器  "
        renamed.directory = "/project"
        renamed = try renamed.validated()
        XCTAssertEqual(renamed.displayName, "开发服务器")
        XCTAssertEqual(renamed.key, original.key)
        XCTAssertNotEqual(renamed.key, ConnectionConfig(host: "other@example.com", port: 2222).key)
        let restored = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(renamed))
        XCTAssertEqual(restored.name, "开发服务器")
    }

    func testIdentityPathIsOneArgumentAndSurvivesPersistence() throws {
        let config = try ConnectionConfig(host: "dev", identityFile: "/Users/example/keys/my key", authentication: .keyFile).validated()
        let restored = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(config))
        let args = SSHConnections.authenticationArguments(restored)
        XCTAssertEqual(Array(args.prefix(2)), ["-i", "/Users/example/keys/my key"])
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        XCTAssertThrowsError(try ConnectionConfig(host: "dev", authentication: .keyFile).validated())
        XCTAssertThrowsError(try ConnectionConfig(host: "dev", identityFile: "/tmp/key\nother", authentication: .keyFile).validated())
    }

    func testPasswordAuthenticationDisablesPublicKeyFallback() throws {
        let config = ConnectionConfig(host: "dev", authentication: .password)
        let args = SSHConnections.authenticationArguments(config)
        XCTAssertTrue(args.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(args.contains("PreferredAuthentications=keyboard-interactive,password"))
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"))
    }

    private static let serverKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeServerKeyForTestsOnly0123456789abcdefghijk"
    private static let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeMacHostKeyForTestsOnly0123456789abcdefghij"

    func testReverseAccessDefaultsOffAndNamesAreSafe() throws {
        let old = try JSONDecoder().decode(ConnectionConfig.self, from: Data(#"{"host":"dev","directory":"~"}"#.utf8))
        XCTAssertNil(old.reverseAccess)
        XCTAssertEqual(ReverseSetup.socketName(hostName: "Studio-Mac-mini.local"), "Studio-Mac-mini")
        XCTAssertEqual(ReverseSetup.socketName(hostName: "a b;rm -rf ~/.local"), "a-b-rm--rf---")
        XCTAssertEqual(ReverseSetup.socketName(hostName: "我的电脑.local"), "mac")
        XCTAssertEqual(ReverseSetup.marker(ConnectionConfig(host: "root@1.2.3.4", port: 22)), "claude-mirror-reverse:root@1.2.3.4_22")
        XCTAssertEqual(ReverseAccess(configPath: "/root/.claude-mirror/reverse/m.config", name: "m").command,
                       "ssh -F '/root/.claude-mirror/reverse/m.config' m")
    }

    func testRemoteScriptPinsHostKeyAndParsesPastLoginBanners() {
        let pinned = ReverseSetup.remoteScript(name: "m", user: "ml", hostKey: Self.hostKey)
        XCTAssertTrue(pinned.contains("StrictHostKeyChecking yes"))
        XCTAssertTrue(pinned.contains("'m \(Self.hostKey)'"))
        XCTAssertTrue(pinned.contains("ControlMaster auto"))
        XCTAssertTrue(ReverseSetup.remoteScript(name: "m", user: "ml", hostKey: nil).contains("StrictHostKeyChecking accept-new"))
        let output = "Welcome!\n__RCC_HOME__=/root\n__RCC_KEY__=\(Self.serverKey) claude-mirror-reverse\n"
        XCTAssertEqual(ReverseSetup.parse(output), ReverseSetup.RemoteInfo(home: "/root", publicKey: Self.serverKey))
        XCTAssertNil(ReverseSetup.parse("__RCC_HOME__=/root\n__RCC_KEY__=ssh-rsa AAAA\n"))
        XCTAssertNil(ReverseSetup.parse("__RCC_KEY__=\(Self.serverKey)\n"))
        XCTAssertNil(ReverseSetup.validKey("ssh-ed25519 short"))
    }

    func testAuthorizedKeysKeepsOtherLinesAndOnlyTouchesItsOwn() throws {
        let marker = "claude-mirror-reverse:a_"
        let mine = ReverseSetup.authorizedLine(publicKey: Self.serverKey, marker: marker)
        XCTAssertTrue(mine.hasPrefix("from=\"127.0.0.1,::1\",no-agent-forwarding,no-X11-forwarding ssh-ed25519 "))
        let original = "ssh-ed25519 AAAAuser me@laptop\n# comment\nssh-ed25519 AAAAother claude-mirror-reverse:b_\n"
        let added = ReverseSetup.updatedAuthorizedKeys(original, marker: marker, line: mine)
        XCTAssertEqual(added, original + mine + "\n")
        XCTAssertEqual(ReverseSetup.updatedAuthorizedKeys(added, marker: marker, line: mine), added)
        XCTAssertEqual(ReverseSetup.updatedAuthorizedKeys(added, marker: marker, line: nil), original)
        XCTAssertEqual(ReverseSetup.updatedAuthorizedKeys("no-newline-at-end", marker: marker, line: nil), "no-newline-at-end\n")
    }

    /// Fake ssh records every call and answers the setup script like a server would.
    private func recordingSSH() throws -> (URL, URL, URL, SSHConnections) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-reverse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("calls.log")
        let ssh = folder.appendingPathComponent("ssh")
        try #"""
        #!/bin/sh
        echo "$*" >> "\#(log.path)"
        case " $* " in *"__RCC_HOME__"*) printf 'motd noise\n__RCC_HOME__=/home/tester\n__RCC_KEY__=\#(Self.serverKey) claude-mirror-reverse\n';; esac
        exit 0
        """#.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let keys = folder.appendingPathComponent("ssh-dir/authorized_keys")
        try FileManager.default.createDirectory(at: keys.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ssh-ed25519 AAAAexisting me@laptop\n".write(to: keys, atomically: true, encoding: .utf8)
        let connections = try SSHConnections(executable: ssh.path)
        connections.localSSHAvailable = { true }
        connections.localHostKey = { Self.hostKey }
        connections.authorizedKeysPath = keys.path
        return (folder, log, keys, connections)
    }

    func testReverseAccessAuthorizesBindsAndFullyRevokes() async throws {
        let (folder, log, keys, connections) = try recordingSSH()
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = ConnectionConfig(host: "dev", reverseAccess: true)
        try await connections.connect(config)
        let name = ReverseSetup.socketName()
        let path = "/home/tester/.claude-mirror/reverse/\(name).sock"
        let access = connections.reverseAccess(config)
        XCTAssertEqual(access.socketPath, path, access.error)
        XCTAssertEqual(access.command, "ssh -F '/home/tester/.claude-mirror/reverse/\(name).config' \(name)")
        var authorized = try String(contentsOf: keys, encoding: .utf8)
        XCTAssertTrue(authorized.hasPrefix("ssh-ed25519 AAAAexisting me@laptop\n"))
        XCTAssertTrue(authorized.contains("from=\"127.0.0.1,::1\",no-agent-forwarding,no-X11-forwarding \(Self.serverKey) claude-mirror-reverse:dev_"))
        let mode = try FileManager.default.attributesOfItem(atPath: keys.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        var calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("-O forward -R \(path):127.0.0.1:22"), calls)

        await connections.setReverseAccess(config, enabled: false)
        calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("-O cancel -R \(path):127.0.0.1:22"), calls)
        XCTAssertTrue(calls.contains("-O exit \(name)"), calls)
        authorized = try String(contentsOf: keys, encoding: .utf8)
        XCTAssertEqual(authorized, "ssh-ed25519 AAAAexisting me@laptop\n")
        XCTAssertNil(connections.reverseAccess(config).socketPath)
        await connections.disconnect(config)
    }

    func testTurningOffWhileOfflineStillRevokesTheKey() async throws {
        let (folder, _, keys, connections) = try recordingSSH()
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = ConnectionConfig(host: "dev", reverseAccess: true)
        try await connections.connect(config)
        await connections.disconnect(config)
        XCTAssertTrue(try String(contentsOf: keys, encoding: .utf8).contains("claude-mirror-reverse:dev_"))
        await connections.setReverseAccess(config, enabled: false)
        XCTAssertEqual(try String(contentsOf: keys, encoding: .utf8), "ssh-ed25519 AAAAexisting me@laptop\n")
    }

    func testReverseAccessIsNotRequestedUnlessEnabledAndReportsMissingRemoteLogin() async throws {
        let (folder, log, keys, connections) = try recordingSSH()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = ConnectionConfig(host: "plain")
        try await connections.connect(plain)
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains(" -R "))
        connections.localSSHAvailable = { false }
        let wanted = ConnectionConfig(host: "wanted", reverseAccess: true)
        try await connections.connect(wanted)
        XCTAssertTrue(connections.reverseAccess(wanted).error.contains("远程登录"))
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains(" -R "))
        XCTAssertEqual(try String(contentsOf: keys, encoding: .utf8), "ssh-ed25519 AAAAexisting me@laptop\n")
        await connections.disconnect(plain); await connections.disconnect(wanted)
    }

    func testInteractiveConnectionPassesAskpassEnvironment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("askpass")
        let ssh = folder.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf test-response".write(to: helper, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        case " $* " in *" -O exit "*) exit 0;; esac
        [ "$SSH_ASKPASS_REQUIRE" = force ] || exit 41
        [ -x "$SSH_ASKPASS" ] || exit 42
        [ "$("$SSH_ASKPASS" 'Password:')" = test-response ] || exit 43
        case " $* " in *" BatchMode=no "*) ;; *) exit 44;; esac
        case " $* " in *" StrictHostKeyChecking=ask "*) ;; *) exit 45;; esac
        exit 0
        """#.write(to: ssh, atomically: true, encoding: .utf8)
        for path in [helper, ssh] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
        let connections = try SSHConnections(executable: ssh.path, askpassPath: helper.path)
        let config = ConnectionConfig(host: "test", authentication: .password)
        try await connections.connect(config)
        XCTAssertEqual(connections.state(config).status, .connected)
        await connections.disconnect(config)
    }
    func testFormPasswordIsEphemeralAndCleanedAfterSSHFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ssh = folder.appendingPathComponent("ssh")
        let record = folder.appendingPathComponent("path")
        let script = """
        #!/bin/sh
        [ "$(cat "$MIRROR_SSH_CREDENTIAL_FILE")" = 'dummy password' ] || exit 41
        [ "$(stat -f %Lp "$MIRROR_SSH_CREDENTIAL_FILE")" = 600 ] || exit 42
        printf '%s' "$MIRROR_SSH_CREDENTIAL_FILE" > '\(record.path)'
        exit 1
        """
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let connections = try SSHConnections(executable: ssh.path, askpassPath: "/unused")
        do {
            try await connections.connect(ConnectionConfig(host: "test", authentication: .password), password: "dummy password")
            XCTFail("Expected SSH failure")
        } catch {}
        let path = try String(contentsOf: record, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

}
