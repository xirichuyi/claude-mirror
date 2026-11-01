#if canImport(AppKit)
import AppKit
import XCTest
@testable import RemoteCC

final class FileDropTests: XCTestCase {
    @MainActor func testFinderFilesUploadAsOneBatchWithoutChangingDraft() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/drop test (1).txt"), URL(fileURLWithPath: "/tmp/附件.txt")]
        board.writeObjects(files as [NSURL])
        let view = PasteAwareTextView()
        view.string = "Existing draft"
        view.acceptsFileDrops = true
        var batches: [[URL]] = []
        var highlighted = true
        view.onDropFiles = { batches.append($0) }
        view.onFileDrag = { highlighted = $0 }

        XCTAssertTrue(view.acceptFileDrop(view.fileURLs(board)))
        XCTAssertEqual(batches, [files])
        XCTAssertEqual(view.string, "Existing draft")
        XCTAssertFalse(highlighted)
    }

    @MainActor func testDisconnectedDropDoesNotUploadOrChangeDraft() {
        let view = PasteAwareTextView()
        view.string = "Draft"
        view.onDropFiles = { _ in XCTFail("Disconnected drop must not upload") }
        XCTAssertFalse(view.acceptFileDrop([URL(fileURLWithPath: "/tmp/file.txt")]))
        XCTAssertEqual(view.string, "Draft")
    }

    @MainActor func testTextAndWebURLsAreNotFileAttachments() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("ordinary text", forType: .string)
        let view = PasteAwareTextView()
        view.acceptsFileDrops = true
        view.onDropFiles = { _ in XCTFail("Non-file content must not upload") }
        XCTAssertTrue(view.fileURLs(board).isEmpty)
        XCTAssertFalse(view.acceptFileDrop([]))
        XCTAssertFalse(view.acceptFileDrop([URL(string: "https://example.com/file.txt")!]))
    }
}
#endif
