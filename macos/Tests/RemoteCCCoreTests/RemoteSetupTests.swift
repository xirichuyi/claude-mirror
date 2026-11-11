import XCTest
@testable import RemoteCCCore

final class RemoteSetupTests: XCTestCase {
    private func info(claude: String? = "/home/u/.local/bin/claude", warning: String? = nil) throws -> ServerInfo {
        var object: [String: Any] = ["home": "/home/u", "nodeSupported": true, "nodePath": "/usr/bin/node", "agentPath": "/a.cjs"]
        if let claude { object["claude"] = claude }
        if let warning { object["persistenceWarning"] = warning }
        return try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testMissingNodeOffersOneClickInstallAndNothingElse() throws {
        let issues = MachineHealth.issues(startError: RemoteSetupError.nodeMissing, info: nil, status: nil)
        XCTAssertEqual(issues.map(\.kind), [.node])
        XCTAssertEqual(issues.first?.action, .install)
        XCTAssertTrue(issues.first?.blocking == true)
        XCTAssertEqual(MachineHealth.issues(startError: RemoteSetupError.nodeOutdated("v16.0.0"), info: nil, status: nil).first?.title.contains("v16.0.0"), true)
        XCTAssertTrue(MachineHealth.issues(startError: RemoteError("other"), info: nil, status: nil).isEmpty)
    }

    func testClaudeInstallLoginAndPersistenceChecklist() throws {
        XCTAssertEqual(MachineHealth.issues(startError: nil, info: try info(claude: nil), status: nil).map(\.kind), [.claude])
        // The fresh status wins over the connection-time path.
        XCTAssertEqual(MachineHealth.issues(startError: nil, info: try info(), status: ClaudeStatus(claude: nil, auth: .unknown)).map(\.kind), [.claude])
        let loggedOut = MachineHealth.issues(startError: nil, info: try info(warning: "会中断"),
                                             status: ClaudeStatus(claude: "/c", auth: .loggedOut, loginCommand: "/c auth login"))
        XCTAssertEqual(loggedOut.map(\.kind), [.login, .persistence])
        XCTAssertEqual(loggedOut[0].action, .login(command: "/c auth login"))
        XCTAssertFalse(loggedOut[1].blocking)
        XCTAssertTrue(MachineHealth.issues(startError: nil, info: try info(), status: ClaudeStatus(claude: "/c", auth: .unknown)).isEmpty)
        XCTAssertTrue(MachineHealth.issues(startError: nil, info: try info(), status: ClaudeStatus(claude: "/c", auth: .loggedIn)).isEmpty)
    }

    func testClaudeStatusDecodesAgentReply() {
        let status = ClaudeStatus(json: ["claude": "/c", "auth": "loggedOut", "loginCommand": "/c auth login"])
        XCTAssertEqual(status, ClaudeStatus(claude: "/c", auth: .loggedOut, loginCommand: "/c auth login"))
        XCTAssertEqual(ClaudeStatus(json: ["auth": "strange"]).auth, .unknown)
    }

    func testConnectionAdviceExplainsCommonFailuresAndKeepsTheOriginal() {
        let denied = ConnectionAdvice.explain("ubuntu@10.0.0.2: Permission denied (publickey,password).")
        XCTAssertTrue(denied.hasPrefix("服务器拒绝了登录"))
        XCTAssertTrue(denied.contains("原始信息：ubuntu@10.0.0.2: Permission denied"))
        XCTAssertTrue(ConnectionAdvice.explain("ssh: Could not resolve hostname devbox: nodename nor servname provided").hasPrefix("找不到这个服务器地址"))
        XCTAssertTrue(ConnectionAdvice.explain("ssh: connect to host 1.2.3.4 port 22: Connection refused").hasPrefix("服务器拒绝连接"))
        XCTAssertTrue(ConnectionAdvice.explain("ssh: connect to host 1.2.3.4 port 22: Operation timed out").hasPrefix("连接超时"))
        XCTAssertTrue(ConnectionAdvice.explain("Host key verification failed.").hasPrefix("服务器的身份指纹"))
        XCTAssertEqual(ConnectionAdvice.explain("  something new  "), "something new")
        XCTAssertEqual(ConnectionAdvice.explain(denied), denied, "explaining twice must not nest")
    }

    func testAuthorizeScriptAppendsOnceAndKeepsExistingKeys() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rcc-key-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try "ssh-ed25519 EXISTING user@laptop".write(toFile: home + "/.ssh/authorized_keys", atomically: true, encoding: .utf8)
        let key = "ssh-ed25519 " + String(repeating: "A", count: 68)
        let script = LoginKeySetup.authorizeScript(publicKey: key)
        for _ in 0..<2 {
            let output = try run("/usr/bin/env", ["HOME=" + home, "/bin/sh", "-c", script])
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("__RCC_KEY_OK__"))
        }
        let text = try String(contentsOfFile: home + "/.ssh/authorized_keys", encoding: .utf8)
        XCTAssertEqual(text, "ssh-ed25519 EXISTING user@laptop\n" + key + " claude-mirror\n")
        let mode = try FileManager.default.attributesOfItem(atPath: home + "/.ssh/authorized_keys")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLoginKeyIsCreatedOnceAndReused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rcc-keygen-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let first = try LoginKeySetup.ensureKey(at: folder + "/ssh/key")
        XCTAssertTrue(first.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(try LoginKeySetup.ensureKey(at: folder + "/ssh/key"), first)
    }

    func testInstallerStreamsMergedOutputAndReportsExitStatus() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rcc-install-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        final class Lines: @unchecked Sendable { let lock = NSLock(); var values: [String] = [] }
        let lines = Lines()
        let script = Data("echo '==> Claude Code'\necho to-stderr >&2\nprintf 'no-newline'\nexit 3\n".utf8)
        let code = try await RemoteInstaller.run(launcher: LocalLauncher(home: home), config: ConnectionConfig(host: "local", directory: "~"),
                                                 script: script) { line in lines.lock.withLock { lines.values.append(line) } }
        XCTAssertEqual(code, 3)
        XCTAssertEqual(lines.values, ["==> Claude Code", "to-stderr", "no-newline"])
        XCTAssertTrue(RemoteInstaller.summary(3).contains("Node.js"))
    }
}
