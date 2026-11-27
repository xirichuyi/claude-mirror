import XCTest
@testable import RemoteCCCore

final class BundleRenameTests: XCTestCase {
    func testOldNamesMoveNextToThemselves() {
        XCTAssertEqual(BundleRename.target(for: URL(fileURLWithPath: "/Applications/claude-mirror.app"))?.path, "/Applications/Tether.app")
        XCTAssertEqual(BundleRename.target(for: URL(fileURLWithPath: "/Users/a/Applications/Claude Mirror.app"))?.path, "/Users/a/Applications/Tether.app")
    }

    func testCurrentOtherAndTranslocatedBundlesStay() {
        XCTAssertNil(BundleRename.target(for: URL(fileURLWithPath: "/Applications/Tether.app")))
        XCTAssertNil(BundleRename.target(for: URL(fileURLWithPath: "/Applications/My Tools.app")))
        XCTAssertNil(BundleRename.target(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1234/d/claude-mirror.app")))
    }
}
