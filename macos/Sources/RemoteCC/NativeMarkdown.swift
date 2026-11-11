#if canImport(AppKit)
import AppKit
import cmark_gfm
import cmark_gfm_extensions
import RemoteCCCore

/// cmark owns parsing; AppKit owns layout. No HTML importer or WebKit is involved.
@MainActor enum NativeMarkdown {
    struct Block: Identifiable {
        enum Kind { case prose, code, table, rule }
        let id: Int
        let kind: Kind
        let content: NSAttributedString
        var language = ""
        var width: CGFloat = 0
    }
    private final class Cached: NSObject { let blocks: [Block]; init(_ blocks: [Block]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>(); cache.countLimit = 64; cache.totalCostLimit = 4 * 1024 * 1024; return cache
    }()
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
        builder.walk(root)
        builder.flush()
        cache.setObject(Cached(builder.blocks), forKey: source as NSString, cost: input.utf8.count + builder.blocks.reduce(0) { $0 + $1.content.length * 12 })
        return builder.blocks
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
    private static func attributes(size: CGFloat = 13, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSTheme.text]
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
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            attrs[.foregroundColor] = ThemeStore.syntaxColor(.string)
            let text = literal(node)
            if text.count < 80 { attrs[.backgroundColor] = NSTheme.surface }
            return NSAttributedString(string: text, attributes: attrs)
        case "strong", "emph":
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: kind == "strong" ? .boldFontMask : .italicFontMask)
        case "strikethrough": attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case "link", "image":
            if let value = cmark_node_get_url(node) {
                let raw = String(cString: value)
                if let url = link(raw) { attrs[.link] = url; attrs[.foregroundColor] = NSTheme.accent }
            }
        default: break
        }
        for child in children(node) { result.append(inline(child, attributes: attrs)) }
        if kind == "image" {
            result.insert(NSAttributedString(string: "[图片] ", attributes: attrs), at: 0)
        }
        return result
    }
    private static func link(_ raw: String) -> URL? {
        let url = URL(string: raw)
        if let scheme = url?.scheme {
            return ["http", "https", "rcc-file", "file"].contains(scheme.lowercased()) ? url : nil
        }
        return URL(string: "rcc-file:" + (raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw))
    }
    @MainActor private final class Builder {
        var blocks: [Block] = []
        var prose = NSMutableAttributedString(string: "")
        func flush() {
            guard prose.length > 0 else { return }
            if prose.string.hasSuffix("\n") { prose.deleteCharacters(in: NSRange(location: prose.length - 1, length: 1)) }
            blocks.append(Block(id: blocks.count, kind: .prose, content: NSAttributedString(attributedString: prose)))
            prose = NSMutableAttributedString(string: "")
        }
        func paragraph(_ content: NSAttributedString, style: NSParagraphStyle, prefix: String = "") {
            // Keep completed prose chunks stable while the last paragraph streams.
            // A single enormous NSTextView otherwise remeasures the whole reply.
            if prose.length >= 4096 { flush() }
            let value = NSMutableAttributedString(string: prefix, attributes: attributes())
            value.append(content); value.append(NSAttributedString(string: "\n", attributes: attributes()))
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
            prose.append(value)
        }
        func walk(_ node: UnsafeMutablePointer<cmark_node>, depth: Int = 0, quote: Bool = false, prefix: String = "", tight: Bool = false) {
            let kind = type(node), indent = CGFloat(depth) * 20 + (quote ? 16 : 0)
            switch kind {
            case "paragraph", "heading":
                let level = kind == "heading" ? Int(cmark_node_get_heading_level(node)) : 0
                let size: CGFloat = level == 1 ? 23 : level == 2 ? 19 : level > 0 ? 16 : 13
                var attrs = attributes(size: size, bold: level > 0)
                if quote { attrs[.foregroundColor] = NSTheme.textMuted }
                let p = style(indent: indent)
                if !prefix.isEmpty {
                    // Indent the marker a little so a list reads as a list, not as loose paragraphs.
                    p.firstLineHeadIndent = max(0, indent - 14)
                    p.headIndent = max(indent, p.firstLineHeadIndent + (prefix as NSString).size(withAttributes: attributes()).width)
                }
                if tight { p.paragraphSpacing = 3 }
                if level > 0 { p.paragraphSpacingBefore = 8; p.paragraphSpacing = 10 }
                paragraph(inline(node, attributes: attrs), style: p, prefix: prefix)
            case "list":
                let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
                var number = Int(cmark_node_get_list_start(node))
                let items = children(node), compact = cmark_node_get_list_tight(node) != 0
                for (position, item) in items.enumerated() {
                    var marker = ordered ? "\(number). " : "• "
                    if type(item) == "tasklist" { marker = cmark_gfm_extensions_get_tasklist_item_checked(item) ? "☑ " : "☐ " }
                    for (index, child) in children(item).enumerated() {
                        // Tight lists keep items close; the last item keeps normal spacing before what follows.
                        walk(child, depth: depth + 1, quote: quote, prefix: index == 0 ? marker : "", tight: compact && position < items.count - 1)
                    }
                    number += 1
                }
            case "block_quote": for child in children(node) { walk(child, depth: depth, quote: true) }
            case "code_block":
                flush()
                let language = cmark_node_get_fence_info(node).map { String(cString: $0).split(separator: " ").first.map(String.init) ?? "" } ?? ""
                // Coloured by the fence language; an unknown or missing one stays plain.
                let value = CodeStyle.attributed(literal(node), grammar: SyntaxGrammar.named(language))
                let width = min(16000, max(120, value.string.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: CodeStyle.font]).width }.max() ?? 120) + 8)
                blocks.append(Block(id: blocks.count, kind: .code, content: value, language: language, width: width))
            case "table": table(node)
            case "thematic_break":
                flush(); blocks.append(Block(id: blocks.count, kind: .rule, content: NSAttributedString(string: "")))
            case "html_block": paragraph(NSAttributedString(string: literal(node), attributes: attributes()), style: style(indent: indent))
            default: for child in children(node) { walk(child, depth: depth, quote: quote, prefix: prefix) }
            }
        }
        func table(_ node: UnsafeMutablePointer<cmark_node>) {
            flush()
            let rows = children(node), columns = max(1, Int(cmark_gfm_extensions_get_table_columns(node)))
            let table = NSTextTable(); table.numberOfColumns = columns; table.layoutAlgorithm = .fixedLayoutAlgorithm; table.collapsesBorders = true
            let width = CGFloat(columns) * 180
            let result = NSMutableAttributedString(string: "")
            let alignments = cmark_gfm_extensions_get_table_alignments(node)
            for (rowIndex, row) in rows.enumerated() {
                for (column, cell) in children(row).enumerated() {
                    let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cellBlock.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                    cellBlock.setWidth(8, type: .absoluteValueType, for: .padding)
                    cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(NSTheme.border)
                    if rowIndex == 0 { cellBlock.backgroundColor = NSTheme.surface }
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
            blocks.append(Block(id: blocks.count, kind: .table, content: result, width: width))
        }
    }
}
#endif
