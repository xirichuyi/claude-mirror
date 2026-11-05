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
private struct MarkdownCodeBlock: View {
    let block: NativeMarkdown.Block
    let selection: TranscriptSelection?
    @State private var hovered = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool

    private var displayed: NSAttributedString {
        // cmark keeps the closing newline for exact copying; don't give it an empty display row.
        let content = block.content
        if content.string.hasSuffix("\n") {
            return content.attributedSubstring(from: NSRange(location: 0, length: content.length - 1))
        }
        return content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !block.language.isEmpty {
                Text(block.language).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).padding(.trailing, 30)
            }
            ScrollView(.horizontal) {
                SelectableTranscriptText(text: displayed.string, attributed: displayed, scope: selection)
                    .frame(width: block.width, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12).padding(.leading, 14).padding(.trailing, 42)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button {
                copyToPasteboard(block.content.string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(WorkbenchTheme.canvas.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).focused($copyFocused)
            .help(copied ? "已复制" : "复制代码").accessibilityLabel("复制代码")
            .opacity(hovered || copyFocused || copied ? 1 : 0)
            .padding(6)
        }
        .onHover { hovered = $0 }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
    }
}

#endif
