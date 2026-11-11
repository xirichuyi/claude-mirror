import AppKit
import SwiftUI
import XCTest
@testable import RemoteCC

@MainActor final class WorkbenchPopupTests: XCTestCase {
    func testRemovalCancelsPendingPresentation() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        let coordinator = WorkbenchPopup<Text>.Coordinator()
        coordinator.update(anchor: anchor, presented: .constant(true), content: AnyView(Text("菜单")))
        coordinator.remove()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(window.childWindows?.contains { $0.identifier?.rawValue == "workbench-popup" } ?? false)
    }

    func testPopupStaysInsideWindowAndRemovalLeavesAnchorUntouched() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let anchor = NSView(frame: NSRect(x: 350, y: 10, width: 32, height: 24))
        root.addSubview(anchor)
        let initial = anchor.frame
        var showing = true
        let coordinator = WorkbenchPopup<Text>.Coordinator()
        coordinator.update(anchor: anchor, presented: Binding(get: { showing }, set: { showing = $0 }),
                           content: AnyView(Text("菜单").frame(width: 220, height: 120)))
        try await Task.sleep(for: .milliseconds(50))
        let container = root.superview ?? root
        let popup = try XCTUnwrap(window.childWindows?.first { $0.identifier?.rawValue == "workbench-popup" })
        let frame = window.convertFromScreen(popup.frame)
        XCTAssertGreaterThanOrEqual(frame.minX, 8)
        XCTAssertGreaterThanOrEqual(frame.minY, 8)
        XCTAssertLessThanOrEqual(frame.maxX, container.bounds.width - 8)
        XCTAssertLessThanOrEqual(frame.maxY, container.bounds.height - 8)
        XCTAssertEqual(anchor.frame, initial)
        coordinator.remove()
        XCTAssertNil(popup.parent)
        XCTAssertEqual(anchor.frame, initial)
    }
}
