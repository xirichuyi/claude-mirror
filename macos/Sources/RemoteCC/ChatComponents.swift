#if canImport(SwiftUI)
import SwiftUI
import AppKit

struct ThinkingCard: View {
    let text: String
    let active: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    if active { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(WorkbenchTheme.inkMuted) }
                    Text(active ? "正在思考…" : "思考过程").font(.callout)
                    if !text.isEmpty { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(WorkbenchTheme.inkMuted) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(text.isEmpty).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton).accessibilityLabel((active ? "正在思考" : "思考过程") + (expanded ? "，收起" : "，展开"))
            if expanded && !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.body).lineSpacing(5).foregroundStyle(WorkbenchTheme.inkMuted)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true)
            }
        }.foregroundStyle(WorkbenchTheme.inkMuted).padding(.vertical, 7).padding(.horizontal, 2)
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
#endif
