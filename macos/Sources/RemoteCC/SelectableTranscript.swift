#if canImport(AppKit)
import AppKit
import SwiftUI
import RemoteCCCore

/// One selection scope per conversation; text stays native and tool controls remain interactive.
@MainActor final class TranscriptSelection: ObservableObject {
    private let views = NSHashTable<TranscriptTextView>.weakObjects()
    func register(_ view: TranscriptTextView) { views.add(view) }
    private var ordered: [TranscriptTextView] {
        views.allObjects.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }
    func clear() { for view in ordered { view.setSelectedRange(NSRange(location: 0, length: 0)) } }
    func select(from origin: TranscriptTextView, anchor: Int, to point: NSPoint) {
        let items = ordered
        guard let start = items.firstIndex(where: { $0 === origin }),
              let end = items.indices.min(by: { distance(items[$0], point) < distance(items[$1], point) }) else { return }
        let offset = items[end].characterIndexForInsertion(at: items[end].convert(point, from: nil))
        for (i, view) in items.enumerated() {
            let length = (view.string as NSString).length
            let lower: Int, upper: Int
            if start == end && i == start { lower = min(anchor, offset); upper = max(anchor, offset) }
            else if i < min(start, end) || i > max(start, end) { lower = 0; upper = 0 }
            else if i == start { lower = end > start ? anchor : 0; upper = end > start ? length : anchor }
            else if i == end { lower = end > start ? 0 : offset; upper = end > start ? offset : length }
            else { lower = 0; upper = length }
            view.setSelectedRange(NSRange(location: min(length, lower), length: max(0, min(length, upper) - min(length, lower))))
        }
    }
    private func distance(_ view: NSView, _ point: NSPoint) -> CGFloat {
        let rect = view.convert(view.bounds, to: nil)
        return max(0, rect.minY - point.y, point.y - rect.maxY)
    }
    var selectedText: String {
        ordered.compactMap { view in
            let range = view.selectedRange()
            return range.length > 0 ? (view.string as NSString).substring(with: range) : nil
        }.joined(separator: "\n\n")
    }
}

@MainActor final class TranscriptTextView: NSTextView {
    weak var selectionScope: TranscriptSelection?
    override func copy(_ sender: Any?) {
        guard let text = selectionScope?.selectedText, !text.isEmpty else { super.copy(sender); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let window, let scope = selectionScope else { super.mouseDown(with: event); return }
        // Peek so normal clicks, links and double-click word selection keep AppKit behavior.
        guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: false), next.type == .leftMouseDragged else {
            scope.clear(); super.mouseDown(with: event); return
        }
        window.makeFirstResponder(self); scope.clear()
        let anchor = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            scope.select(from: self, anchor: anchor, to: next.locationInWindow)
            if next.type == .leftMouseUp { break }
            // Code and tables have their own horizontal scroller. Drag selection
            // must still reach the outer conversation's vertical scroller.
            var ancestor = superview
            var vertical: NSScrollView?
            while let view = ancestor {
                if let scroll = view as? NSScrollView,
                   (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 1 { vertical = scroll }
                ancestor = view.superview
            }
            (vertical ?? enclosingScrollView)?.contentView.autoscroll(with: next)
        }
    }
}

struct SelectableTranscriptText: NSViewRepresentable {
    let text: String
    var markdown = true
    var attributed: NSAttributedString?
    var scope: TranscriptSelection?
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: TranscriptTextView, context: Context) {
        context.coordinator.open = open
        view.selectionScope = scope; scope?.register(view)
        guard context.coordinator.source != text || context.coordinator.attributed != attributed else { return }
        context.coordinator.attributed = attributed
        context.coordinator.source = text
        context.coordinator.measuredWidth = nil
        let range = view.selectedRange()
        view.textStorage?.setAttributedString(attributed ?? Self.render(text, markdown: markdown))
        if NSMaxRange(range) <= (view.string as NSString).length { view.setSelectedRange(range) }
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TranscriptTextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? 600
        let available = max(1, floor(proposed.isFinite ? proposed : 600))
        if context.coordinator.measuredWidth == available { return context.coordinator.measuredSize }
        let width: CGFloat
        if markdown { width = available }
        else {
            let natural = view.attributedString().boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).width
            width = min(available, ceil(natural) + 2)
        }
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: ceil(layout.usedRect(for: container).height) + 2)
        context.coordinator.measuredWidth = available
        context.coordinator.measuredSize = size
        return size
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: String?
        var attributed: NSAttributedString?
        var measuredWidth: CGFloat?
        var measuredSize: CGSize?
        var open: (URL) -> Void = { _ in }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open(url) }
            else if let value = link as? String, let url = URL(string: value) { open(url) }
            return true
        }
    }
    static func render(_ text: String, markdown: Bool) -> NSAttributedString {
        if markdown { return NativeMarkdown.document(text) }
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSTheme.text])
    }

}
private struct TranscriptSelectionKey: EnvironmentKey {
    static let defaultValue: TranscriptSelection? = nil
}
extension EnvironmentValues {
    var transcriptSelection: TranscriptSelection? {
        get { self[TranscriptSelectionKey.self] }
        set { self[TranscriptSelectionKey.self] = newValue }
    }
}
#endif
