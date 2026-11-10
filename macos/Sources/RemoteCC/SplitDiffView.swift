import SwiftUI
import AppKit
import RemoteCCCore

/// Winc's paired diff: independent horizontal scrolling, synchronized vertical scrolling,
/// centre gutters, word highlights, change ribbons, counts and change navigation.
struct SplitDiffView: View {
    let text: String
    let path: String
    @State private var selectedChange = 0

    var body: some View {
        let diff = SplitDiff(text)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("原始版本").foregroundStyle(WorkbenchTheme.inkMuted)
                Spacer(minLength: 4)
                Text("+\(diff.added)").foregroundStyle(WorkbenchTheme.added)
                Text("−\(diff.removed)").foregroundStyle(WorkbenchTheme.inkDim)
                Text(diff.changes.isEmpty ? "0 / 0" : "\(min(selectedChange + 1, diff.changes.count)) / \(diff.changes.count)")
                    .monospacedDigit().foregroundStyle(WorkbenchTheme.inkMuted)
                Button { move(-1, diff: diff) } label: { Image(systemName: "chevron.up") }
                    .help("上一处改动").accessibilityLabel("上一处改动").disabled(diff.changes.isEmpty)
                Button { move(1, diff: diff) } label: { Image(systemName: "chevron.down") }
                    .help("下一处改动").accessibilityLabel("下一处改动").disabled(diff.changes.isEmpty)
                Spacer(minLength: 4)
                Text("工作区版本").foregroundStyle(WorkbenchTheme.inkMuted)
            }.font(WorkbenchMetrics.caption).buttonStyle(QuietButtonStyle())
                .padding(.horizontal, 12).frame(height: 36)
                .overlay(alignment: .bottom) { WorkbenchTheme.separator.frame(height: 1) }
            if diff.rows.isEmpty {
                InterfaceState(title: "没有差异", detail: "此文件与 Git 中的版本一致。", symbol: "checkmark.circle")
                    .frame(maxHeight: .infinity)
            } else {
                PairedDiffPane(text: text, path: path, selectedChange: selectedChange)
            }
            WorkbenchStatusBar {
                Image(systemName: "arrow.left.arrow.right"); Text("并排比较")
                Spacer(); Text((path as NSString).lastPathComponent)
            }
        }.onChange(of: text) { selectedChange = 0 }
    }
    private func move(_ offset: Int, diff: SplitDiff) {
        guard !diff.changes.isEmpty else { return }
        selectedChange = (selectedChange + offset + diff.changes.count) % diff.changes.count
    }
}

private struct PairedDiffPane: NSViewRepresentable {
    let text: String
    let path: String
    let selectedChange: Int
    func makeNSView(context: Context) -> PairedDiffDocument { PairedDiffDocument() }
    func updateNSView(_ view: PairedDiffDocument, context: Context) { view.update(text: text, path: path, change: selectedChange) }
}

/// Native text selection and find remain available in both columns. Only the visible line fills
/// and gutters are drawn; long files do not instantiate a SwiftUI view for every cell.
private final class PairedDiffDocument: NSView {
    private let left = DiffTextView(), right = DiffTextView()
    private let leftScroll = NSScrollView(), rightScroll = NSScrollView()
    private let gutter = DiffCentreGutter()
    private var observers: [NSObjectProtocol] = []
    private var source: String?
    private var sourcePath = ""
    private var selected = -1
    private var diff = SplitDiff("")
    private var syncing = false
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for (scroll, text, title) in [(leftScroll, left, "原始版本"), (rightScroll, right, "工作区版本")] {
            scroll.documentView = text
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true; scroll.borderType = .noBorder
            scroll.drawsBackground = true; scroll.backgroundColor = NSTheme.card
            text.isEditable = false; text.isSelectable = true; text.isRichText = true
            text.drawsBackground = true; text.backgroundColor = NSTheme.card
            text.isVerticallyResizable = true; text.isHorizontallyResizable = true
            text.autoresizingMask = []; text.textContainerInset = NSSize(width: 8, height: 8)
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude)
            text.usesFindBar = true
            text.setAccessibilityLabel(title)
            addSubview(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll else { return }; self.synchronize(from: scroll)
            })
        }
        addSubview(gutter)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func layout() {
        super.layout()
        let middle: CGFloat = 92
        let width = max(0, (bounds.width - middle) / 2)
        leftScroll.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        gutter.frame = NSRect(x: width, y: 0, width: middle, height: bounds.height)
        rightScroll.frame = NSRect(x: width + middle, y: 0, width: width, height: bounds.height)
        resizeDocuments()
    }
    func update(text: String, path: String, change: Int) {
        if source != text || sourcePath != path {
            source = text; sourcePath = path; diff = SplitDiff(text)
            left.rows = diff.rows; right.rows = diff.rows; gutter.rows = diff.rows
            left.textStorage?.setAttributedString(attributed(leftSide: true, path: path))
            right.textStorage?.setAttributedString(attributed(leftSide: false, path: path))
            selected = -1; resizeDocuments()
        }
        if selected != change {
            selected = change
            if diff.changes.indices.contains(change) {
                let y = max(0, CGFloat(diff.changes[change].lowerBound) * CodeStyle.lineHeight - bounds.height / 3)
                leftScroll.contentView.scroll(to: NSPoint(x: leftScroll.contentView.bounds.minX, y: y))
                leftScroll.reflectScrolledClipView(leftScroll.contentView)
                synchronize(from: leftScroll)
            }
        }
    }
    private func attributed(leftSide: Bool, path: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let grammar = SyntaxGrammar.named((path as NSString).pathExtension)
        for row in diff.rows {
            let side = leftSide ? row.left : row.right
            let line = NSMutableAttributedString(attributedString: CodeStyle.attributed((side.text ?? "") + "\n", grammar: row.kind == .hunk ? nil : grammar))
            if let range = side.changed, NSMaxRange(range) < line.length {
                line.addAttribute(.backgroundColor, value: diffColor(row.kind).withAlphaComponent(0.25), range: range)
            }
            result.append(line)
        }
        return result
    }
    private func resizeDocuments() {
        for (view, scroll) in [(left, leftScroll), (right, rightScroll)] {
            guard let layout = view.layoutManager, let container = view.textContainer else { continue }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            view.setFrameSize(NSSize(width: max(scroll.contentSize.width, used.width + 24), height: max(scroll.contentSize.height, used.height + 16)))
        }
    }
    private func synchronize(from source: NSScrollView) {
        guard !syncing else { return }; syncing = true
        defer { syncing = false }
        let target = source === leftScroll ? rightScroll : leftScroll
        let y = source.contentView.bounds.minY
        if abs(target.contentView.bounds.minY - y) > 0.5 {
            target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: y))
            target.reflectScrolledClipView(target.contentView)
        }
        gutter.offset = y; gutter.needsDisplay = true
    }
}

private func diffColor(_ kind: SplitDiff.Kind) -> NSColor {
    switch kind {
    case .added: ThemeStore.dynamic { $0.gitAdded }
    case .removed: NSTheme.textMuted
    case .modified: ThemeStore.dynamic { $0.gitModified }
    case .hunk: NSTheme.textMuted
    case .context: .clear
    }
}

private final class DiffTextView: NSTextView {
    var rows: [SplitDiff.Row] = []
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let start = max(0, Int((rect.minY - 8) / CodeStyle.lineHeight))
        let end = min(rows.count, Int((rect.maxY - 8) / CodeStyle.lineHeight) + 1)
        guard start < end else { return }
        for index in start..<end {
            diffColor(rows[index].kind).withAlphaComponent(rows[index].kind == .context ? 0 : 0.09).setFill()
            NSRect(x: rect.minX, y: 8 + CGFloat(index) * CodeStyle.lineHeight, width: rect.width, height: CodeStyle.lineHeight).fill()
        }
    }
}

private final class DiffCentreGutter: NSView {
    var rows: [SplitDiff.Row] = []
    var offset: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSTheme.card.setFill(); bounds.fill()
        NSTheme.surface.setFill(); NSRect(x: 36, y: 0, width: 20, height: bounds.height).fill()
        let start = max(0, Int((offset - 8) / CodeStyle.lineHeight))
        let end = min(rows.count, Int((offset + bounds.height) / CodeStyle.lineHeight) + 1)
        guard start < end else { return }
        let paragraph = CodeStyle.paragraph(); paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: CodeStyle.font, .foregroundColor: NSTheme.gutter, .paragraphStyle: paragraph, .baselineOffset: CodeStyle.baselineOffset(CodeStyle.font)]
        for index in start..<end {
            let row = rows[index], y = 8 + CGFloat(index) * CodeStyle.lineHeight - offset
            if row.change != nil {
                let ribbon = NSBezierPath()
                ribbon.move(to: NSPoint(x: 36, y: y)); ribbon.line(to: NSPoint(x: 56, y: y + (row.right.text == nil ? 8 : 0)))
                ribbon.line(to: NSPoint(x: 56, y: y + CodeStyle.lineHeight)); ribbon.line(to: NSPoint(x: 36, y: y + CodeStyle.lineHeight)); ribbon.close()
                diffColor(row.kind).withAlphaComponent(0.18).setFill(); ribbon.fill()
            }
            NSAttributedString(string: row.left.number.map(String.init) ?? "", attributes: attributes).draw(in: NSRect(x: 0, y: y, width: 30, height: CodeStyle.lineHeight))
            NSAttributedString(string: row.right.number.map(String.init) ?? "", attributes: attributes).draw(in: NSRect(x: 56, y: y, width: 30, height: CodeStyle.lineHeight))
        }
    }
}
