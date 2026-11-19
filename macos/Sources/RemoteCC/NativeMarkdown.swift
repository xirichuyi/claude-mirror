#if canImport(AppKit)
import AppKit
import cmark_gfm
import cmark_gfm_extensions
import RemoteCCCore

/// cmark owns parsing; AppKit owns layout. No HTML importer or WebKit is involved.
@MainActor enum NativeMarkdown {
    struct Block: Identifiable {
        enum Kind { case prose, code, table, rule }
        var id: Int
        let kind: Kind
        let content: NSAttributedString
        var language = ""
        var width: CGFloat = 0
        /// Laid-out height of a code block, from its line count.
        var height: CGFloat = 0
    }
    private final class Cached: NSObject { let blocks: [Block]; init(_ blocks: [Block]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>(); cache.countLimit = 64; cache.totalCostLimit = 4 * 1024 * 1024; return cache
    }()
    /// What one top-level node produced, keyed by its type and source lines. A streamed reply is parsed
    /// again for every chunk, but only its last node changes; the others are reused instead of rebuilt.
    private final class Pieces: NSObject { let items: [Piece]; init(_ items: [Piece]) { self.items = items } }
    private static let pieces: NSCache<NSString, Pieces> = {
        let cache = NSCache<NSString, Pieces>(); cache.countLimit = 512; cache.totalCostLimit = 8 * 1024 * 1024; return cache
    }()
    private enum Piece { case prose(NSAttributedString), block(Block) }

    /// Top-level nodes paired with their source lines, or nil when their output cannot be reused:
    /// a link reference definition changes how other nodes render, and line ranges that do not tile
    /// the document would give two different nodes the same key.
    private static func sources(_ nodes: [UnsafeMutablePointer<cmark_node>], in input: String) -> [String]? {
        // Bytes, not characters: this runs over the whole reply for every streamed chunk.
        let bytes = input.utf8
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 13 || (byte == 58 && previous == 93) { return nil }
            previous = byte
        }
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        let blank = { (line: Substring.UTF8View) in line.allSatisfy { $0 == 32 || $0 == 9 } }
        var result: [String] = [], next = 0
        for node in nodes {
            let first = Int(cmark_node_get_start_line(node)) - 1, last = Int(cmark_node_get_end_line(node))
            guard first >= next, last > first, last <= lines.count, lines[next..<first].allSatisfy(blank) else { return nil }
            result.append(type(node) + "\n" + input[lines[first].startIndex..<lines[last - 1].endIndex])
            next = last
        }
        return lines[next...].allSatisfy(blank) ? result : nil
    }

    static func blocks(_ source: String) -> [Block] {
        if let cached = cache.object(forKey: source as NSString) { return cached.blocks }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tasklist", "table"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        let input = RemoteFileLinks.markdown(source)
        cmark_parser_feed(parser, input, input.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        let builder = Builder()
        let nodes = children(root)
        if let sources = sources(nodes, in: input) {
            for (index, node) in nodes.enumerated() {
                // The last node is still growing while a reply streams, so it is never stored.
                guard index < nodes.count - 1 else { builder.walk(node); break }
                if let stored = pieces.object(forKey: sources[index] as NSString) { builder.items += stored.items; continue }
                let start = builder.items.count
                builder.walk(node)
                pieces.setObject(Pieces(Array(builder.items[start...])), forKey: sources[index] as NSString, cost: sources[index].utf8.count * 16)
            }
        } else {
            builder.walk(root)
        }
        let blocks = builder.blocks
        cache.setObject(Cached(blocks), forKey: source as NSString, cost: input.utf8.count + blocks.reduce(0) { $0 + $1.content.length * 12 })
        return blocks
    }
    static func document(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in blocks(source) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(block.content)
        }
        return result
    }
    private static func type(_ node: UnsafeMutablePointer<cmark_node>) -> String { String(cString: cmark_node_get_type_string(node)) }
    private static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String { cmark_node_get_literal(node).map { String(cString: $0) } ?? "" }
    private static func children(_ node: UnsafeMutablePointer<cmark_node>) -> [UnsafeMutablePointer<cmark_node>] {
        var result: [UnsafeMutablePointer<cmark_node>] = [], current = cmark_node_first_child(node)
        while let child = current { result.append(child); current = cmark_node_next(child) }
        return result
    }
    private static func style(indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping; style.lineSpacing = 4; style.paragraphSpacing = 9
        style.firstLineHeadIndent = indent; style.headIndent = indent
        return style
    }
    /// Faint fill behind inline code and table headers; the window background colour does not show on the canvas.
    private static let tint = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.055) }
    private static func attributes(size: CGFloat = 13, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(WorkbenchTheme.ink)]
    }
    private static func inline(_ node: UnsafeMutablePointer<cmark_node>, attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let kind = type(node)
        var attrs = attrs
        switch kind {
        case "text", "html_inline": return NSAttributedString(string: literal(node), attributes: attrs)
        case "softbreak": return NSAttributedString(string: " ", attributes: attrs)
        case "linebreak": return NSAttributedString(string: "\n", attributes: attrs)
        case "code":
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let text = literal(node)
            if text.count < 80 { attrs[.backgroundColor] = tint }
            return NSAttributedString(string: text, attributes: attrs)
        case "strong", "emph":
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: kind == "strong" ? .boldFontMask : .italicFontMask)
        case "strikethrough": attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case "link", "image":
            if let value = cmark_node_get_url(node) {
                let raw = String(cString: value)
                if let url = link(raw) { attrs[.link] = url; attrs[.foregroundColor] = NSColor(WorkbenchTheme.accent) }
            }
        default: break
        }
        for child in children(node) { result.append(inline(child, attributes: attrs)) }
        if kind == "image" {
            result.insert(NSAttributedString(string: "[图片] ", attributes: attrs), at: 0)
        }
        return result
    }
    /// A code block that is still streaming is measured again for every chunk; only its new lines cost anything.
    private static var codeLineWidths: [String: CGFloat] = [:]
    private static func codeLineWidth(_ line: String) -> CGFloat {
        if let width = codeLineWidths[line] { return width }
        if codeLineWidths.count >= 4096 { codeLineWidths.removeAll(keepingCapacity: true) }
        let width = (line as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)]).width
        codeLineWidths[line] = width
        return width
    }
    private static func link(_ raw: String) -> URL? {
        let url = URL(string: raw)
        if let scheme = url?.scheme {
            return ["http", "https", "rcc-file", "file"].contains(scheme.lowercased()) ? url : nil
        }
        return URL(string: "rcc-file:" + (raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw))
    }
    @MainActor private final class Builder {
        var items: [Piece] = []
        /// Consecutive prose joins into one selectable text block; code, tables and rules stand alone.
        var blocks: [Block] {
            var blocks: [Block] = []
            var prose = NSMutableAttributedString(string: "")
            func flush() {
                guard prose.length > 0 else { return }
                if prose.string.hasSuffix("\n") { prose.deleteCharacters(in: NSRange(location: prose.length - 1, length: 1)) }
                blocks.append(Block(id: blocks.count, kind: .prose, content: NSAttributedString(attributedString: prose)))
                prose = NSMutableAttributedString(string: "")
            }
            for item in items {
                switch item {
                case .prose(let value): prose.append(value)
                case .block(var block):
                    flush()
                    block.id = blocks.count
                    blocks.append(block)
                }
            }
            flush()
            return blocks
        }
        func paragraph(_ content: NSAttributedString, style: NSParagraphStyle, prefix: String = "") {
            let value = NSMutableAttributedString(string: prefix, attributes: attributes())
            value.append(content); value.append(NSAttributedString(string: "\n", attributes: attributes()))
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
            items.append(.prose(value))
        }
        func walk(_ node: UnsafeMutablePointer<cmark_node>, depth: Int = 0, quote: NSTextBlock? = nil, prefix: String = "") {
            let kind = type(node), indent = CGFloat(depth) * 20
            switch kind {
            case "paragraph", "heading":
                let level = kind == "heading" ? Int(cmark_node_get_heading_level(node)) : 0
                let size: CGFloat = level == 1 ? 23 : level == 2 ? 19 : level > 0 ? 16 : 13
                var attrs = attributes(size: size, bold: level > 0)
                if quote != nil { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
                let p = style(indent: indent)
                if let quote { p.textBlocks = [quote] }
                if !prefix.isEmpty {
                    p.firstLineHeadIndent = max(0, indent - 20)
                    p.headIndent = max(indent, p.firstLineHeadIndent + (prefix as NSString).size(withAttributes: attributes()).width)
                }
                if level > 0 { p.paragraphSpacingBefore = 8; p.paragraphSpacing = 10 }
                paragraph(inline(node, attributes: attrs), style: p, prefix: prefix)
            case "list":
                let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
                var number = Int(cmark_node_get_list_start(node))
                for item in children(node) {
                    var marker = ordered ? "\(number). " : "• "
                    if type(item) == "tasklist" { marker = cmark_gfm_extensions_get_tasklist_item_checked(item) ? "☑ " : "☐ " }
                    for (index, child) in children(item).enumerated() {
                        walk(child, depth: depth + 1, quote: quote, prefix: index == 0 ? marker : "")
                    }
                    number += 1
                }
            case "block_quote":
                // One text block for the whole quote draws a continuous bar down its left side.
                let bar = NSTextBlock()
                bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                bar.setBorderColor(.tertiaryLabelColor)
                bar.setValue(100, type: .percentageValueType, for: .width)
                bar.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                for child in children(node) { walk(child, depth: depth, quote: quote ?? bar) }
            case "code_block":
                let codeStyle = style(); codeStyle.paragraphSpacing = 0; codeStyle.lineSpacing = 3
                let value = NSMutableAttributedString(string: literal(node), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor(WorkbenchTheme.ink), .paragraphStyle: codeStyle])
                let width = min(16000, max(120, value.string.components(separatedBy: "\n").map(codeLineWidth).max() ?? 120) + 8)
                let language = cmark_node_get_fence_info(node).map { String(cString: $0).split(separator: " ").first.map(String.init) ?? "" } ?? ""
                CodeHighlight.apply(to: value, language: language)
                let lines = value.string.components(separatedBy: "\n").count - (value.string.hasSuffix("\n") ? 1 : 0)
                items.append(.block(Block(id: 0, kind: .code, content: value, language: language, width: width, height: CGFloat(lines) * 19)))
            case "table": table(node)
            case "thematic_break":
                items.append(.block(Block(id: 0, kind: .rule, content: NSAttributedString(string: ""))))
            case "html_block": paragraph(NSAttributedString(string: literal(node), attributes: attributes()), style: style(indent: indent))
            default: for child in children(node) { walk(child, depth: depth, quote: quote, prefix: prefix) }
            }
        }
        func table(_ node: UnsafeMutablePointer<cmark_node>) {
            let rows = children(node), columns = max(1, Int(cmark_gfm_extensions_get_table_columns(node)))
            let table = NSTextTable(); table.numberOfColumns = columns; table.layoutAlgorithm = .fixedLayoutAlgorithm; table.collapsesBorders = true
            let width = CGFloat(columns) * 180
            // The table is narrower than its text view; filling it exactly clips the right border.
            table.setContentWidth(width, type: .absoluteValueType)
            let result = NSMutableAttributedString(string: "")
            let alignments = cmark_gfm_extensions_get_table_alignments(node)
            for (rowIndex, row) in rows.enumerated() {
                for (column, cell) in children(row).enumerated() {
                    let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cellBlock.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                    cellBlock.setWidth(8, type: .absoluteValueType, for: .padding)
                    cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(NSColor(WorkbenchTheme.border))
                    if rowIndex == 0 { cellBlock.backgroundColor = tint }
                    let p = style(); p.textBlocks = [cellBlock]; p.paragraphSpacing = 0
                    if column < columns, let alignment = alignments?[column] {
                        if alignment == 99 { p.alignment = .center }
                        if alignment == 114 { p.alignment = .right }
                    }
                    let value = NSMutableAttributedString(attributedString: inline(cell, attributes: attributes(bold: rowIndex == 0)))
                    value.append(NSAttributedString(string: "\n")); value.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: value.length))
                    result.append(value)
                }
            }
            items.append(.block(Block(id: 0, kind: .table, content: result, width: width + 2)))
        }
    }
}
#endif
