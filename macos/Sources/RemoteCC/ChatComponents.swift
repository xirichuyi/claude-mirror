#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct ThinkingCard: View {
    let text: String
    let active: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                DisclosureGroup(isExpanded: $expanded.animation(Motion.animation(Motion.tree, reduce: reduceMotion))) {
                    ScrollView {
                        Text(text)
                            .font(.body).lineSpacing(5).foregroundStyle(WorkbenchTheme.inkMuted)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                } label: { title }
                    .accessibilityLabel((active ? "正在思考" : "思考过程") + (expanded ? "，收起" : "，展开"))
            }
        }.foregroundStyle(WorkbenchTheme.inkMuted).padding(.vertical, 2).padding(.horizontal, 2)
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
            }.foregroundStyle(WorkbenchTheme.inkMuted).padding(.horizontal, 14).padding(.vertical, 3)
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
    let onReachedBottom: () -> Void
    func makeNSView(context: Context) -> ReadingView {
        let view = ReadingView()
        view.onReadEarlier = onReadEarlier; view.onReachedBottom = onReachedBottom
        return view
    }
    func updateNSView(_ view: ReadingView, context: Context) {
        view.onReadEarlier = onReadEarlier; view.onReachedBottom = onReachedBottom
    }
    static func dismantleNSView(_ view: ReadingView, coordinator: ()) { view.removeMonitor() }

    final class ReadingView: NSView {
        var onReadEarlier: (() -> Void)?
        var onReachedBottom: (() -> Void)?
        private var monitor: Any?
        private var liveScrollObserver: NSObjectProtocol?
        private var endScrollObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            liveScrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self, let scroll = notification.object as? NSScrollView,
                      scroll.window === self.window else { return }
                let rect = self.convert(scroll.bounds, from: scroll)
                if rect.intersects(self.bounds), rect.height > self.bounds.height / 2 { self.onReadEarlier?() }
            }
            endScrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self, let scroll = notification.object as? NSScrollView,
                      scroll.window === self.window, let document = scroll.documentView else { return }
                let rect = self.convert(scroll.bounds, from: scroll)
                guard rect.intersects(self.bounds), rect.height > self.bounds.height / 2 else { return }
                let visible = scroll.documentVisibleRect
                let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
                if ReplyScrollPolicy.isNearBottom(distance) { self.onReachedBottom?() }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    if event.scrollingDeltaY != 0 { self.onReadEarlier?() }
                }
                return event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }; liveScrollObserver = nil
            if let endScrollObserver { NotificationCenter.default.removeObserver(endScrollObserver) }; endScrollObserver = nil
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            if let endScrollObserver { NotificationCenter.default.removeObserver(endScrollObserver) }
        }
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

#endif

/// Publish scroll-state boundaries, never per-pixel geometry. macOS owns wheel momentum.
struct TranscriptScrollTracking: ViewModifier {
    @Binding var farFromBottom: Bool
    @Binding var following: Bool
    @State private var userScrolling = false
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY > 24
                } action: { _, far in farFromBottom = far }
                .onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        userScrolling = true
                        following = false
                    } else if phase == .idle && userScrolling {
                        userScrolling = false
                        let distance = context.geometry.contentSize.height - context.geometry.visibleRect.maxY
                        following = ReplyScrollPolicy.isNearBottom(distance)
                    }
                }
        } else {
            content.background(ScrollReadingDetector(onReadEarlier: { following = false }, onReachedBottom: { following = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }
    }
}
