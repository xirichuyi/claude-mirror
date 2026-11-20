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
    @MainActor func testScreenshotPasteAcceptsPNGAndTIFFWithoutChangingDraft() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let data = try XCTUnwrap(type == .png ? bitmap.representation(using: .png, properties: [:]) : bitmap.tiffRepresentation)
            board.setData(data, forType: type)
            let view = PasteAwareTextView()
            view.isRichText = false
            view.string = "保留草稿"
            var pasted: Data?
            view.onPasteImage = { pasted = $0 }
            XCTAssertTrue(view.readablePasteboardTypes.contains(type))
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertNotNil(pasted.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertEqual(view.string, "保留草稿")
        }
    }

    @MainActor func testCopiedFinderImageUploadsOriginalFile() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/图片.png")
        board.writeObjects([url as NSURL])
        let view = PasteAwareTextView()
        view.isRichText = false
        view.string = "Draft"
        var files: [URL] = []
        view.onDropFiles = { files = $0 }
        view.onPasteImage = { _ in XCTFail("Keep the original file") }
        XCTAssertTrue(view.readSelection(from: board))
        XCTAssertEqual(files, [url])
        XCTAssertEqual(view.string, "Draft")
    }

    @MainActor func testPlainTextPasteStillInsertsAtCaret() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hello", forType: .string)
        let view = PasteAwareTextView()
        view.isRichText = false
        view.string = "ab"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.onPasteImage = { _ in XCTFail("Text must remain text") }
        XCTAssertTrue(view.readSelection(from: board))
        XCTAssertEqual(view.string, "ahellob")
    }

}
#endif
