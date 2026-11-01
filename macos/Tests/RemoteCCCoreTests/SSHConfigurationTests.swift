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
}
