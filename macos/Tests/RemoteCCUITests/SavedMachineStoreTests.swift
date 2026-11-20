import Foundation
import XCTest
import RemoteCCCore
@testable import RemoteCC

final class SavedMachineStoreTests: XCTestCase {
    func testRemovedHostDoesNotReturnFromHistoryAfterRelaunch() throws {
        let suite = "saved-machine-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedMachineStore(defaults: defaults)
        let removed = ConnectionConfig(host: "removed")
        let kept = ConnectionConfig(host: "kept")
        store.save([removed, kept])
        store.markRemoved(removed.key)

        let reopened = SavedMachineStore(defaults: defaults)
        XCTAssertEqual(reopened.load(discovered: [removed, kept]).map(\.key), [kept.key])
        reopened.allow(removed.key)
        XCTAssertEqual(reopened.load(discovered: [removed, kept]).map(\.key), [removed.key, kept.key])
    }

    func testSavedConfigurationWinsOverOlderDiscoveredCopy() throws {
        let suite = "saved-machine-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedMachineStore(defaults: defaults)
        var renamed = ConnectionConfig(host: "example")
        renamed.name = "Renamed"
        store.save([renamed])
        XCTAssertEqual(store.load(discovered: [ConnectionConfig(host: "example")]).map(\.displayName), ["Renamed"])
    }
}
