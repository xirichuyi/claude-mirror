import XCTest
@testable import RemoteCCCore

final class ConnectionCodeTests: XCTestCase {
    private let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJicQEkLt46JTOUutsQxgSDR9f2KuTIuIlLprFr65vfd"
    private let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"

    private func code(_ lines: [String]) -> String {
        let text = Data((lines.joined(separator: "\n") + "\n").utf8).base64EncodedString()
        return "cm1." + text.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    func testParsesWhatTheServerPrints() throws {
        let text = code(["claude-mirror 1", "name box", "host 203.0.113.5", "port 2222", "user alice", "hostkey " + hostKey, privateKey])
        let parsed = try ConnectionCode.parse("  " + text + "\n")
        XCTAssertEqual(parsed.name, "box")
        XCTAssertEqual(parsed.destination, "alice@203.0.113.5")
        XCTAssertEqual(parsed.port, 2222)
        XCTAssertEqual(parsed.privateKey, privateKey + "\n")
        XCTAssertEqual(parsed.knownHostsLines, ["[203.0.113.5]:2222 " + hostKey])
        XCTAssertTrue(ConnectionCode.looksLike(text))
    }

    func testRejectsCodesThatCouldNotLogInSafely() {
        let valid = ["claude-mirror 1", "host h.example", "port 22", "user alice", "hostkey " + hostKey, privateKey]
        XCTAssertThrowsError(try ConnectionCode.parse("cm2.abc"))
        XCTAssertThrowsError(try ConnectionCode.parse(code(valid.filter { !$0.hasPrefix("hostkey") })))
        XCTAssertThrowsError(try ConnectionCode.parse(code(valid.map { $0 == "user alice" ? "user a;b" : $0 })))
        XCTAssertThrowsError(try ConnectionCode.parse(code(valid.map { $0 == "host h.example" ? "host -oProxyCommand=x" : $0 })))
        XCTAssertThrowsError(try ConnectionCode.parse(code(["claude-mirror 2"] + valid.dropFirst())))
        XCTAssertEqual(try ConnectionCode.parse(code(valid)).knownHostsLines, ["h.example " + hostKey])
    }

    func testKnownHostsKeepsExistingLines() {
        XCTAssertEqual(ConnectionCode.addingKnownHosts("a k", lines: ["b k"]), "a k\nb k\n")
        XCTAssertEqual(ConnectionCode.addingKnownHosts("a k\nb k\n", lines: ["b k"]), "a k\nb k\n")
    }
}
