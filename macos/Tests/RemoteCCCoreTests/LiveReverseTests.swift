import XCTest
@testable import RemoteCCCore

/// Real server, real sshd on this Mac: the server must reach this Mac only through the app's master.
final class LiveReverseTests: XCTestCase {
    private func run(_ ssh: SSHConnections, _ config: ConnectionConfig, _ command: String) async throws -> String {
        let child = try ssh.spawn(config, command: command)
        child.closeInput()
        let collected = Collected()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            child.readOutput(chunk: { collected.append($0) }, done: { done.resume() })
        }
        _ = await child.waitForExit()
        return collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testServerReachesThisMacThroughTheAppConnection() async throws {
        guard let host = ProcessInfo.processInfo.environment["REMOTECC_LIVE_HOST"] else {
            throw XCTSkip("Set REMOTECC_LIVE_HOST to run real SSH integration")
        }
        guard SSHConnections.localPortOpen(22) else { throw XCTSkip("Remote Login is off on this Mac") }
        let ssh = try SSHConnections()
        let config = ConnectionConfig(host: host, reverseAccess: true)
        try await ssh.connect(config)
        let access = ssh.reverseAccess(config)
        let path = try XCTUnwrap(access.socketPath, access.error)
        let login = try XCTUnwrap(access.command) + " 'echo via-reverse:$(whoami)' 2>&1"
        let mode = try await run(ssh, config, "stat -c %a " + shellQuote(path) + " 2>/dev/null || stat -f %Lp " + shellQuote(path))
        XCTAssertEqual(mode, "600")
        // Real login with the dedicated key and the pinned host key, no prompts.
        let first = try await run(ssh, config, login)
        XCTAssertEqual(first, "via-reverse:" + NSUserName())

        // A dropped master leaves a stale socket behind; the next connection must still bind.
        await ssh.disconnect(config)
        try await ssh.connect(config)
        XCTAssertEqual(ssh.reverseAccess(config).socketPath, path)
        let again = try await run(ssh, config, login)
        XCTAssertEqual(again, "via-reverse:" + NSUserName())

        // Turning it off must lock the server out, not just hide the socket.
        await ssh.setReverseAccess(config, enabled: false)
        let gone = try await run(ssh, config, "test -e " + shellQuote(path) + " && echo present || echo absent")
        XCTAssertEqual(gone, "absent")
        let locked = try await run(ssh, config, login)
        XCTAssertFalse(locked.contains("via-reverse"), locked)
        let authorized = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/authorized_keys", encoding: .utf8)) ?? ""
        XCTAssertFalse(authorized.contains(ReverseSetup.marker(config)))
        await ssh.disconnect(config)
        await ssh.closeAll()
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
