#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

/// File-type marks in the reference design's manner: short coloured text badges for source
/// files, outline symbols for folders, packages, locks and media. Colours come from the palette.
struct FileKind {
    enum Mark { case badge(String), symbol(String) }
    let mark: Mark
    let tone: SyntaxKind?
    /// Shown in the editor status bar.
    let language: String

    static func of(_ name: String) -> FileKind {
        let lower = name.lowercased()
        if let special = specials[lower] { return special }
        if lower.hasSuffix(".lock") || lower.hasSuffix("-lock.json") || lower.hasSuffix(".sum") { return FileKind(mark: .symbol("lock"), tone: nil, language: "锁文件") }
        if lower.hasPrefix(".env") { return FileKind(mark: .symbol("gearshape"), tone: .decorator, language: "环境变量") }
        return byExtension[(lower as NSString).pathExtension] ?? FileKind(mark: .symbol("doc"), tone: nil, language: "纯文本")
    }

    private static func badge(_ text: String, _ tone: SyntaxKind?, _ language: String) -> FileKind { FileKind(mark: .badge(text), tone: tone, language: language) }
    private static func symbol(_ name: String, _ tone: SyntaxKind?, _ language: String) -> FileKind { FileKind(mark: .symbol(name), tone: tone, language: language) }

    private static let specials: [String: FileKind] = [
        "dockerfile": symbol("shippingbox", .function, "Dockerfile"), "containerfile": symbol("shippingbox", .function, "Dockerfile"),
        "makefile": badge("MK", .decorator, "Makefile"), "package.json": symbol("shippingbox", .keyword, "JSON"),
        "cargo.toml": symbol("shippingbox", .keyword, "TOML"), "license": symbol("checkmark.seal", .builtin, "许可证"),
        ".gitignore": symbol("eye.slash", .comment, "Git 忽略规则"), "readme.md": badge("#", .function, "Markdown"),
    ]
    private static let byExtension: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) { for ext in extensions.split(separator: " ") { table[String(ext)] = kind } }
        add(badge("RS", .keyword, "Rust"), "rs")
        add(badge("SW", .keyword, "Swift"), "swift")
        add(badge("TS", .function, "TypeScript"), "ts mts cts")
        add(badge("TSX", .function, "TSX"), "tsx")
        add(badge("JS", .decorator, "JavaScript"), "js mjs cjs")
        add(badge("JSX", .decorator, "JSX"), "jsx")
        add(badge("PY", .builtin, "Python"), "py pyi")
        add(badge("GO", .builtin, "Go"), "go")
        add(badge("C", .function, "C"), "c h")
        add(badge("C++", .function, "C++"), "cc cpp cxx hpp hh")
        add(badge("C#", .number, "C#"), "cs")
        add(badge("JV", .keyword, "Java"), "java")
        add(badge("KT", .number, "Kotlin"), "kt kts")
        add(badge("RB", .property, "Ruby"), "rb")
        add(badge("PHP", .number, "PHP"), "php")
        add(badge("LUA", .function, "Lua"), "lua")
        add(badge(">_", .string, "Shell"), "sh bash zsh fish")
        add(badge("SQL", .decorator, "SQL"), "sql")
        add(badge("{}", .decorator, "JSON"), "json jsonc json5 jsonl")
        add(badge("Y", .property, "YAML"), "yaml yml")
        add(badge("T", .keyword, "TOML"), "toml")
        add(badge("<>", .property, "HTML"), "html htm xhtml vue svelte")
        add(badge("<>", .comment, "XML"), "xml plist xaml csproj")
        add(badge("#", .function, "CSS"), "css scss sass less")
        add(badge("#", .function, "Markdown"), "md markdown mdx")
        add(badge("≡", .comment, "纯文本"), "txt log")
        add(badge("⚙", .comment, "配置"), "ini cfg conf properties")
        add(symbol("photo", .string, "图片"), "png jpg jpeg gif webp bmp ico heic tiff")
        add(symbol("square.on.circle", .number, "SVG"), "svg")
        add(symbol("doc.richtext", .keyword, "PDF"), "pdf")
        add(symbol("film", .number, "视频"), "mp4 mov webm mkv")
        add(symbol("archivebox", .comment, "压缩包"), "zip tar gz tgz bz2 xz 7z")
        return table
    }()
}

struct FileIcon: View {
    let name: String
    var directory = false
    var expanded = false

    var body: some View {
        Group {
            if directory {
                WorkbenchIcon(symbol: expanded ? "folder.open" : "folder").font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(WorkbenchTheme.inkMuted)
            } else {
                let kind = FileKind.of(name)
                let color = Color(nsColor: ThemeStore.syntaxColor(kind.tone == nil ? .comment : kind.tone))
                switch kind.mark {
                case .badge(let text):
                    Text(text).font(.system(size: text.count > 2 ? 6.5 : 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                case .symbol(let symbol):
                    WorkbenchIcon(symbol: symbol).font(.system(size: 11)).foregroundStyle(color)
                }
            }
        }
        .frame(width: 18, height: 16)
        .accessibilityHidden(true)
    }
}
#endif
