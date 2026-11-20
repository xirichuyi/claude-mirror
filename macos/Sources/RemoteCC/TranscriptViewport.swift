import AppKit
import SwiftUI
import RemoteCCCore

/// Plain per-session storage: scrolling never publishes AppModel changes.
final class TranscriptViewport {
    var window = TranscriptWindow()
    var following = true
    var offset: CGPoint?
}

/// Capture the native clip origin, including the partial first line. Restoring an
/// item ID alone loses this offset and visibly jumps when switching conversations.
struct TranscriptViewportBridge: NSViewRepresentable {
    let state: TranscriptViewport
    func makeNSView(context: Context) -> Probe { Probe(state: state) }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        let state: TranscriptViewport
        private weak var scroll: NSScrollView?
        private var observer: NSObjectProtocol?
        private var restoring = true
        init(state: TranscriptViewport) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { detach(); return }
            // SwiftUI installs its initial scroll anchor in this layout pass.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard let scroll = enclosingScrollView, observer == nil else { return }
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in self?.capture() }
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }
        private func restore() {
            guard let scroll, let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            if !state.following, let offset = state.offset {
                let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: CGPoint(x: offset.x, y: min(maxY, max(0, offset.y))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            restoring = false
            capture()
        }
        private func capture() {
            guard !restoring, let scroll, scroll.contentView.bounds.height > 0 else { return }
            state.offset = scroll.contentView.bounds.origin
        }
        func detach() {
            capture()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
