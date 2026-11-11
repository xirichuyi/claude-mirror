#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RemoteCCCore

enum PromptKey { case up, down, tab, enter, escape }

/// NSTextView rather than TextEditor: Enter handling must respect Chinese input-method composition,
/// which only the AppKit text system can report.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int
    let placeholder: String
    let handler: (PromptKey) -> Bool
    let onPasteImage: (Data) -> Void
    let onDropFiles: ([URL]) -> Void
    let acceptsFileDrops: Bool
    let onFileDrag: (Bool) -> Void
    var focusToken: UUID? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let original = scroll.documentView as! NSTextView
        let view = PasteAwareTextView(frame: original.frame, textContainer: original.textContainer)
        view.minSize = original.minSize; view.maxSize = original.maxSize
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = original.autoresizingMask
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes[.paragraphStyle] = paragraph
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        view.delegate = context.coordinator
        view.onContentHeight = onHeightChange
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.onPasteImage = onPasteImage
        view.onDropFiles = onDropFiles
        view.acceptsFileDrops = acceptsFileDrops
        view.onFileDrag = onFileDrag
        view.registerForDraggedTypes([.fileURL])
        scroll.documentView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PasteAwareTextView else { return }
        view.onContentHeight = onHeightChange
        view.onPasteImage = onPasteImage
        view.onDropFiles = onDropFiles
        view.acceptsFileDrops = acceptsFileDrops
        view.onFileDrag = onFileDrag
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        view.needsDisplay = true
        let requestedFocus = context.coordinator.focusToken != focusToken
        if requestedFocus {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        // Never rewrite the text during input-method composition.
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: requestedFocus ? (text as NSString).length : min(caret, (text as NSString).length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var focusToken: UUID?
        init(_ parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.caret = view.selectedRange().location
            parent.text = view.string
            (view as? PasteAwareTextView)?.measureContentHeight()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let location = view.selectedRange().location
            if parent.caret != location { DispatchQueue.main.async { self.parent.caret = location } }
        }
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            // During composition these keys belong to the input method.
            if view.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift) { view.insertNewlineIgnoringFieldEditor(nil); return true }
                return parent.handler(.enter)
            case #selector(NSResponder.moveUp(_:)): return parent.handler(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.handler(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.handler(.tab)
            case #selector(NSResponder.cancelOperation(_:)): return parent.handler(.escape)
            default: return false
            }
        }
    }
}

final class PasteAwareTextView: NSTextView {
    var onContentHeight: ((CGFloat) -> Void)?
    private var lastContentHeight: CGFloat = 0
    override func layout() {
        super.layout()
        measureContentHeight()
    }
    func measureContentHeight() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = min(180, max(32, ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)))
        guard abs(height - lastContentHeight) > 0.5 else { return }
        lastContentHeight = height
        DispatchQueue.main.async { [weak self] in self?.onContentHeight?(height) }
    }
    var onPasteImage: ((Data) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var acceptsFileDrops = false
    var onFileDrag: ((Bool) -> Void)?

    func fileURLs(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender.draggingPasteboard).isEmpty else { return super.draggingEntered(sender) }
        onFileDrag?(acceptsFileDrops)
        return acceptsFileDrops ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender.draggingPasteboard).isEmpty else { return super.draggingUpdated(sender) }
        return acceptsFileDrops ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDrag?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !fileURLs(sender.draggingPasteboard).isEmpty else { return super.prepareForDragOperation(sender) }
        return acceptsFileDrops
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        return acceptFileDrop(urls)
    }

    @discardableResult
    func acceptFileDrop(_ urls: [URL]) -> Bool {
        onFileDrag?(false)
        guard acceptsFileDrops, !urls.isEmpty, urls.allSatisfy(\.isFileURL), let onDropFiles else { return false }
        onDropFiles(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onFileDrag?(false)
        super.concludeDragOperation(sender)
    }
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        // Use the event's modifiers; global modifier state can change before the delegate runs.
        if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.shift) {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let inset = textContainerInset
            (placeholder as NSString).draw(in: NSRect(x: inset.width + (textContainer?.lineFragmentPadding ?? 5), y: inset.height,
                width: max(0, bounds.width - 2 * inset.width - 10), height: bounds.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

    // AppKit uses these types to enable Paste before dispatching the action.
    // A plain-text NSTextView otherwise rejects image-only clipboards.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    override func readSelection(from board: NSPasteboard) -> Bool {
        let files = fileURLs(board)
        if !files.isEmpty, let onDropFiles {
            onDropFiles(files)
            return true
        }
        // Keep rich text with an embedded image as text, preserving normal paste.
        if board.string(forType: .string) != nil {
            return super.readSelection(from: board)
        }
        if let onPasteImage {
            if let png = board.data(forType: .png), NSBitmapImageRep(data: png) != nil {
                onPasteImage(png)
                return true
            }
            if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                onPasteImage(png)
                return true
            }
        }
        return super.readSelection(from: board)
    }
}
#endif
