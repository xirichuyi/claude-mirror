import XCTest
@testable import RemoteCCCore

final class FullAccessTests: XCTestCase {
    func testExecutionIdentityAndPermissionModeSurvivePersistence() throws {
        var preferences = Preferences()
        preferences.permissionMode = "bypassPermissions"
        preferences.executionUser = "claude-runner"
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
    }

    func testPermissionCapabilitiesRemainCompatibleWithOlderServers() throws {
        let old = try JSONDecoder().decode(Capabilities.self, from: Data(#"{"commands":[],"models":[]}"#.utf8))
        XCTAssertNil(old.permissionStatus)
        let root = try JSONDecoder().decode(Capabilities.self, from: Data(#"{"commands":[],"models":[],"permissionStatus":{"fullAccessAvailable":false,"requiresExecutionUser":true,"executionUser":"root"}}"#.utf8))
        XCTAssertEqual(root.permissionStatus?.requiresExecutionUser, true)
        XCTAssertEqual(root.permissionStatus?.fullAccessAvailable, false)
    }
}
