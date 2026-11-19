#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct ThinkingCard: View {
    let text: String
    let active: Bool
    @State private var expanded = false

    /// Same row as a tool call: disclosure arrow first, then status icon and title.
    private var title: some View {
        HStack(spacing: 7) {
            if active { ProgressView().controlSize(.mini) }
            else { Image(systemName: "checkmark.circle") }
            Text(active ? "正在思考…" : "思考过程").fontWeight(.medium)
        }.font(.caption)
    }

    var body: some View {
        Group {
            if text.isEmpty { title.padding(.leading, 16) }
            else {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView {
                        Text(text)
                            .font(.body).lineSpacing(5).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                } label: { title }
                    .accessibilityLabel((active ? "正在思考" : "思考过程") + (expanded ? "，收起" : "，展开"))
            }
        }.foregroundStyle(.secondary).padding(.vertical, 2).padding(.horizontal, 2)
    }
}

struct FencedCodeView: View {
    let text: String
    let language: String
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.system(size: 11, weight: .medium, design: .monospaced))
                Spacer()
                Button { copyToPasteboard(text); copied = true } label: {
                    Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(QuietButtonStyle()).font(.subheadline)
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 3)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(highlightedCode(text, language: language)).font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }.defaultScrollAnchor(.topLeading).frame(maxHeight: 380).fixedSize(horizontal: false, vertical: true)
        }.background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium).strokeBorder(WorkbenchTheme.border))
            .task(id: copied) {
                if copied { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
            }
    }
}

/// macOS wheel events are not SwiftUI drag gestures. Observe only events over this
/// message viewport, return every event unchanged, and remove the monitor on teardown.
struct ScrollReadingDetector: NSViewRepresentable {
    let onReadEarlier: () -> Void
    func makeNSView(context: Context) -> ReadingView {
        let view = ReadingView(); view.onReadEarlier = onReadEarlier; return view
    }
    func updateNSView(_ view: ReadingView, context: Context) { view.onReadEarlier = onReadEarlier }
    static func dismantleNSView(_ view: ReadingView, coordinator: ()) { view.removeMonitor() }

    final class ReadingView: NSView {
        var onReadEarlier: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    if event.type == .scrollWheel && event.scrollingDeltaY > 0 { self.onReadEarlier?() }
                    // Clicking a message may start text selection or drag the scrollbar.
                    if event.type == .leftMouseDown { self.onReadEarlier?() }
                }
                return event
            }
        }
        func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// A scroll view for content wider than its column. While more remains to the right the trailing
/// edge fades out, so clipped code, tool output and tables read as scrollable instead of cut off.
struct OverflowScroll<Content: View>: View {
    var axes: Axis.Set = .horizontal
    var anchor: UnitPoint = .topLeading
    @ViewBuilder let content: Content
    @State private var more = false

    var body: some View {
        ScrollView(axes) { content.background(TrailingOverflowObserver { more = $0 }) }
            .defaultScrollAnchor(anchor)
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: more ? 32 : 0)
                }
            }
    }
}

/// Reports whether the enclosing scroll view has content beyond its trailing edge. Only changes are reported.
private struct TrailingOverflowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var queued = false, more = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
            document.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [(NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip), (NSView.frameDidChangeNotification, document)].map { name, object in
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.queueUpdate() } }
            }
            queueUpdate()
        }
        func stopObserving() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }

        /// Notifications arrive in the middle of layout; SwiftUI state may only change afterwards.
        private func queueUpdate() {
            guard !queued else { return }
            queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queued = false
                guard let scroll = self.enclosingScrollView, let document = scroll.documentView else { return }
                let more = document.frame.maxX - scroll.contentView.bounds.maxX > 1
                if more != self.more { self.more = more; self.onChange?(more) }
            }
        }
    }
}

/// Sits inside the transcript's scroll content and reads the enclosing `NSScrollView`.
/// A SwiftUI geometry preference is not updated while the scroll view scrolls or grows on current macOS,
/// and storing the offset in view state would re-evaluate the whole transcript on every scroll frame.
struct ReplyScrollObserver: NSViewRepresentable {
    /// Whether new reply text should keep the end of the transcript in view.
    let follows: Bool
    let selection: TranscriptSelection
    /// Called only when a `ReplyScrollPolicy` threshold is crossed.
    let onChange: (_ farFromEnd: Bool, _ nearEnd: Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.follows = follows; view.selection = selection; view.onChange = onChange
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var follows = true
        weak var selection: TranscriptSelection?
        var onChange: ((Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var updateQueued = false, followQueued = false
        private var far = false, near = true
        /// Set when the viewport or the transcript changed size, as opposed to being scrolled.
        private var reflowed = false
        /// The line at the top of the viewport while the user reads earlier messages.
        private var reading: (view: TranscriptTextView, character: Int, inset: CGFloat)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
            document.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.queueUpdate() } },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reflowed = true; self?.queueUpdate() } },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reflowed = true; self?.queueUpdate(); self?.queueFollow() } }
            ]
        }
        func stopObserving() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }

        /// Notifications arrive in the middle of layout; SwiftUI state may only change afterwards.
        private func queueUpdate() {
            guard !updateQueued else { return }
            updateQueued = true
            DispatchQueue.main.async { [weak self] in self?.updateQueued = false; self?.update() }
        }

        private func update() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            // A reflow keeps the line being read where it was; only scrolling picks a new one.
            let reflowed = self.reflowed
            self.reflowed = false
            if reflowed, !follows { restoreReadingLine(clip, in: scroll) }
            let distance = Double(document.frame.maxY - clip.bounds.maxY)
            let far = ReplyScrollPolicy.showsJump(distance: distance, following: false), near = ReplyScrollPolicy.isNearBottom(distance)
            if far != self.far || near != self.near { self.far = far; self.near = near; onChange?(far, near) }
            if follows || near { reading = nil }
            else if !reflowed { reading = readingLine(clip) }
        }

        /// Keeps the end of a growing reply in view. Runs after layout, once per pass, and glides
        /// to the new end so streamed lines do not arrive as jumps.
        private func queueFollow() {
            guard follows, !followQueued else { return }
            followQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.followQueued = false
                guard self.follows, let scroll = self.enclosingScrollView, let document = scroll.documentView else { return }
                let clip = scroll.contentView
                let end = NSPoint(x: clip.bounds.minX, y: document.frame.maxY - clip.bounds.height)
                let distance = end.y - clip.bounds.minY
                guard distance > 0.5 else { return }
                // A long way off is a new message or a resize, not the next line of the reply.
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || distance > clip.bounds.height / 2 {
                    clip.scroll(to: end)
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        clip.animator().setBoundsOrigin(end)
                    }
                }
                scroll.reflectScrolledClipView(clip)
            }
        }

        private func lineTop(_ view: TranscriptTextView, character: Int) -> CGFloat? {
            guard let layout = view.layoutManager, let container = view.textContainer, layout.numberOfGlyphs > 0 else { return nil }
            layout.ensureLayout(for: container)
            let glyph = min(layout.glyphIndexForCharacter(at: character), layout.numberOfGlyphs - 1)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return view.convert(NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y), to: nil).y
        }

        private func readingLine(_ clip: NSClipView) -> (view: TranscriptTextView, character: Int, inset: CGFloat)? {
            let top = clip.convert(clip.bounds, to: nil).maxY
            for view in selection?.visibleViews ?? [] {
                let frame = view.convert(view.bounds, to: nil)
                guard frame.minY < top else { continue }
                let character = view.characterIndexForInsertion(at: view.convert(NSPoint(x: frame.minX + 1, y: min(top, frame.maxY) - 1), from: nil))
                guard let lineTop = lineTop(view, character: character) else { continue }
                return (view, character, top - lineTop)
            }
            return nil
        }

        private func restoreReadingLine(_ clip: NSClipView, in scroll: NSScrollView) {
            guard let reading, reading.view.window != nil, let document = scroll.documentView,
                  let lineTop = lineTop(reading.view, character: reading.character) else { return }
            let top = clip.convert(clip.bounds, to: nil).maxY
            let limit = max(0, document.frame.maxY - clip.bounds.height)
            // The document is flipped: a line that sits lower than before needs a larger origin.
            let y = min(limit, max(0, clip.bounds.minY + ((top - lineTop) - reading.inset)))
            guard abs(y - clip.bounds.minY) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
#endif
