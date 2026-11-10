#if canImport(AppKit)
import AppKit
import SwiftUI
import RemoteCCCore

struct MarkdownView: View {
    let text: String
    let actions: FileActions
    @Environment(\.transcriptSelection) private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(NativeMarkdown.blocks(text)) { block in
                if block.kind == .rule {
                    Rectangle().fill(WorkbenchTheme.border).frame(height: 1).padding(.vertical, 4)
                } else if block.kind == .prose {
                    selectable(block)
                } else if block.kind == .code {
                    MarkdownCodeBlock(block: block, selection: selection)
                } else {
                    ScrollView(.horizontal) {
                        selectable(block).frame(width: block.width, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func selectable(_ block: NativeMarkdown.Block) -> some View {
        SelectableTranscriptText(text: block.content.string, attributed: block.content, scope: selection) { url in
            if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            else if let reference = RemoteFileLinks.reference(url) { actions.open(reference.path, reference.line) }
        }
    }

}
/// A code card: a header with the language, line count and copy action, then highlighted code
/// with a line-number gutter for anything longer than a snippet.
private struct MarkdownCodeBlock: View {
    let block: NativeMarkdown.Block
    let selection: TranscriptSelection?
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayed: NSAttributedString {
        // cmark keeps the closing newline for exact copying; don't give it an empty display row.
        let content = block.content
        if content.string.hasSuffix("\n") {
            return content.attributedSubstring(from: NSRange(location: 0, length: content.length - 1))
        }
        return content
    }
    private var lines: Int { displayed.string.components(separatedBy: "\n").count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(block.language.isEmpty ? "代码" : block.language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(WorkbenchTheme.inkMuted).lineLimit(1)
                Spacer(minLength: 8)
                if lines > 1 { Text("\(lines) 行").font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkDim) }
                Button {
                    copyToPasteboard(block.content.string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11)).foregroundStyle(copied ? WorkbenchTheme.added : WorkbenchTheme.inkMuted)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(QuietButtonStyle())
                .help(copied ? "已复制" : "复制代码").accessibilityLabel("复制代码")
            }
            .padding(.leading, 12).padding(.trailing, 2).frame(height: 30)
            .background(WorkbenchTheme.hover)
            Rectangle().fill(WorkbenchTheme.separator).frame(height: 1)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    if lines > 3 {
                        // Not part of the selection scope, so copied text never carries numbers.
                        SelectableTranscriptText(text: "", markdown: false, attributed: CodeStyle.gutter(lines: lines), scope: nil)
                            .fixedSize().accessibilityHidden(true)
                    }
                    SelectableTranscriptText(text: displayed.string, attributed: displayed, scope: selection)
                        .frame(width: block.width, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WorkbenchTheme.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.medium, style: .continuous).strokeBorder(WorkbenchTheme.border))
        .animation(Motion.animation(Motion.hover, reduce: reduceMotion), value: copied)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
    }
}

#endif
