import Foundation

/// The nine token kinds a code palette colours. Plain text needs no span.
public enum SyntaxKind: String, Sendable, CaseIterable {
    case keyword, builtin, string, number, comment, function, decorator, property
}

/// A coloured range in UTF-16 units, so it applies directly to an NSAttributedString.
public struct SyntaxSpan: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let kind: SyntaxKind
    public init(location: Int, length: Int, kind: SyntaxKind) { self.location = location; self.length = length; self.kind = kind }
    public var range: NSRange { NSRange(location: location, length: length) }
}

/// A single-pass lexer per language family. Like a line-oriented editor highlighter it favours
/// speed and never fails: unknown syntax stays plain, and an unterminated string stops at the
/// end of its line so one stray quote cannot colour the rest of a file.
public struct SyntaxGrammar: Sendable {
    public enum Mode: Sendable { case code, markup, css, data, markdown }
    var mode: Mode = .code
    var keywords: Set<String> = []
    var builtins: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    var quotes: Set<UInt16> = [quote, apostrophe]
    /// Quotes whose strings may span lines (JavaScript template literals, Go raw strings).
    var multilineQuotes: Set<UInt16> = []
    var tripleQuotes = false
    /// Single quotes delimit short character literals (C, Rust, Go, Java), not strings.
    var characterLiterals = false
    var decorators = false
    var rustAttributes = false
    var preprocessor = false
    var capitalizedTypes = false
    var shellVariables = false
    /// Data formats: a key before `:` or `=` is a property.
    var keyValue = false

    public static func named(_ name: String) -> SyntaxGrammar? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let family = aliases[key] else { return nil }
        return family
    }

    /// Picks a grammar from a file name, including extension-less names such as `Makefile`.
    public static func forFile(_ path: String) -> SyntaxGrammar? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let special = specialFiles[name] { return named(special) }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : named(ext)
    }
}

private let quote: UInt16 = 34, apostrophe: UInt16 = 39, backtick: UInt16 = 96, backslash: UInt16 = 92
private let newline: UInt16 = 10, space: UInt16 = 32, tab: UInt16 = 9, carriage: UInt16 = 13

private func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

private let cFamilyKeywords = "if else for while do switch case default break continue return goto sizeof typedef struct union enum static extern const volatile inline register auto restrict"
private let swiftGrammar = SyntaxGrammar(
    keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw throws switch where while as is try await async actor nonisolated isolated some any super self Self get set willSet didSet lazy weak unowned mutating nonmutating override final required convenience dynamic indirect optional consuming borrowing macro package"),
    builtins: words("true false nil Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character Array Dictionary Set Optional Result Void Never Any AnyObject Error"),
    lineComments: ["//"], blockComment: ("/*", "*/"), multilineQuotes: [], tripleQuotes: true, decorators: true, capitalizedTypes: true)
private let scriptGrammar = SyntaxGrammar(
    keywords: words("break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield async await as implements interface package private protected public type enum declare namespace module abstract readonly keyof infer satisfies get set"),
    builtins: words("true false null undefined NaN Infinity console window document globalThis Promise Array Object String Number Boolean Map Set Symbol Error JSON Math Date RegExp any unknown never void string number boolean bigint object"),
    lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [quote, apostrophe, backtick], multilineQuotes: [backtick], decorators: true, capitalizedTypes: true)
private let pythonGrammar = SyntaxGrammar(
    keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case type"),
    builtins: words("True False None self cls print len range str int float bool list dict set tuple object type isinstance super Exception ValueError TypeError KeyError open enumerate zip map filter sorted any all min max sum"),
    lineComments: ["#"], tripleQuotes: true, decorators: true)
private let goGrammar = SyntaxGrammar(
    keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
    builtins: words("true false nil iota bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any append cap close copy delete len make new panic print println recover"),
    lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [quote, apostrophe, backtick], multilineQuotes: [backtick], characterLiterals: true, capitalizedTypes: true)
private let rustGrammar = SyntaxGrammar(
    keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while"),
    builtins: words("true false Some None Ok Err i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc"),
    lineComments: ["//"], blockComment: ("/*", "*/"), characterLiterals: true, rustAttributes: true, capitalizedTypes: true)
private let jvmGrammar = SyntaxGrammar(
    keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var val fun object when is in out override open data sealed companion internal lateinit suspend record yield"),
    builtins: words("true false null void boolean byte char short int long float double String Object Integer List Map Set Unit Any"),
    lineComments: ["//"], blockComment: ("/*", "*/"), multilineQuotes: [], tripleQuotes: true, characterLiterals: true, decorators: true, capitalizedTypes: true)
private let cGrammar = SyntaxGrammar(
    keywords: words(cFamilyKeywords + " class namespace template typename public private protected virtual override final friend operator new delete this throw try catch using noexcept constexpr consteval decltype explicit mutable nullptr static_cast dynamic_cast reinterpret_cast const_cast co_await co_return co_yield concept requires interface implementation end property synthesize self"),
    builtins: words("void char short int long float double signed unsigned bool size_t ssize_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t true false NULL nullptr std string vector map auto id nil YES NO"),
    lineComments: ["//"], blockComment: ("/*", "*/"), characterLiterals: true, decorators: false, preprocessor: true, capitalizedTypes: true)
private let csharpGrammar = SyntaxGrammar(
    keywords: words("abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while async await var get set init record when where yield"),
    builtins: words("true false null bool byte char decimal double float int long object sbyte short string uint ulong ushort void dynamic"),
    lineComments: ["//"], blockComment: ("/*", "*/"), characterLiterals: true, preprocessor: true, capitalizedTypes: true)
private let shellGrammar = SyntaxGrammar(
    keywords: words("if then else elif fi for while until do done case esac in function select return break continue local export readonly declare unset shift source alias set trap exit"),
    builtins: words("echo printf cd pwd ls cat grep sed awk find xargs test true false read eval exec mkdir rm cp mv chmod chown curl git npm node sudo"),
    lineComments: ["#"], shellVariables: true)
private let rubyGrammar = SyntaxGrammar(
    keywords: words("alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader private protected public"),
    builtins: words("true false nil puts print p String Integer Array Hash Symbol"),
    lineComments: ["#"], capitalizedTypes: true)
private let phpGrammar = SyntaxGrammar(
    keywords: words("abstract and as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield"),
    builtins: words("true false null array string int float bool void mixed self parent"),
    lineComments: ["//", "#"], blockComment: ("/*", "*/"), capitalizedTypes: true, shellVariables: true)
private let sqlGrammar = SyntaxGrammar(
    keywords: words("select from where and or not insert into values update set delete create table drop alter add column index view join left right inner outer full on as group by order having limit offset union all distinct case when then else end is null like in between exists primary key foreign references default unique begin commit rollback transaction with returning SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE DROP ALTER ADD COLUMN INDEX VIEW JOIN LEFT RIGHT INNER OUTER FULL ON AS GROUP BY ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT CASE WHEN THEN ELSE END IS NULL LIKE IN BETWEEN EXISTS PRIMARY KEY FOREIGN REFERENCES DEFAULT UNIQUE BEGIN COMMIT ROLLBACK TRANSACTION WITH RETURNING"),
    builtins: words("int integer bigint smallint text varchar char boolean bool date timestamp real float double numeric decimal serial json jsonb uuid true false INT INTEGER BIGINT TEXT VARCHAR CHAR BOOLEAN DATE TIMESTAMP REAL FLOAT NUMERIC DECIMAL SERIAL JSON UUID TRUE FALSE count sum avg min max COUNT SUM AVG MIN MAX"),
    lineComments: ["--"], blockComment: ("/*", "*/"))
private let luaGrammar = SyntaxGrammar(
    keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
    builtins: words("true false nil self print pairs ipairs require table string math"),
    lineComments: ["--"])
private let jsonGrammar = SyntaxGrammar(mode: .data, builtins: words("true false null"), quotes: [quote], keyValue: true)
private let yamlGrammar = SyntaxGrammar(mode: .data, builtins: words("true false null yes no on off True False Null ~"), lineComments: ["#"], keyValue: true)
private let tomlGrammar = SyntaxGrammar(mode: .data, builtins: words("true false"), lineComments: ["#"], tripleQuotes: true, keyValue: true)
private let iniGrammar = SyntaxGrammar(mode: .data, builtins: words("true false yes no on off"), lineComments: ["#", ";"], keyValue: true)
private let markupGrammar = SyntaxGrammar(mode: .markup, blockComment: ("<!--", "-->"), quotes: [quote, apostrophe])
private let cssGrammar = SyntaxGrammar(mode: .css, builtins: words("important inherit initial unset none auto"), blockComment: ("/*", "*/"))
private let markdownGrammar = SyntaxGrammar(mode: .markdown)
private let dockerGrammar = SyntaxGrammar(
    keywords: words("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"),
    lineComments: ["#"], shellVariables: true)
private let makeGrammar = SyntaxGrammar(keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export override"), lineComments: ["#"], shellVariables: true)

private let aliases: [String: SyntaxGrammar] = {
    var table: [String: SyntaxGrammar] = [:]
    func add(_ grammar: SyntaxGrammar, _ names: String) { for name in names.split(separator: " ") { table[String(name)] = grammar } }
    add(swiftGrammar, "swift")
    add(scriptGrammar, "js javascript jsx mjs cjs ts typescript tsx mts cts vue svelte")
    add(pythonGrammar, "py python python3 pyi")
    add(goGrammar, "go golang")
    add(rustGrammar, "rs rust")
    add(jvmGrammar, "java kt kts kotlin scala groovy gradle dart")
    add(cGrammar, "c h cc cpp cxx hpp hh hxx c++ objc objective-c m mm cuda cu")
    add(csharpGrammar, "cs csharp c#")
    add(shellGrammar, "sh bash zsh shell fish ksh console shellscript ps1 powershell")
    add(rubyGrammar, "rb ruby rake gemspec")
    add(phpGrammar, "php")
    add(sqlGrammar, "sql psql mysql sqlite postgres postgresql")
    add(luaGrammar, "lua")
    add(jsonGrammar, "json jsonc json5 jsonl geojson ipynb")
    add(yamlGrammar, "yaml yml")
    add(tomlGrammar, "toml")
    add(iniGrammar, "ini cfg conf properties env editorconfig gitconfig")
    add(markupGrammar, "html htm xml xhtml svg plist xaml csproj vbproj props targets storyboard xib")
    add(cssGrammar, "css scss sass less")
    add(markdownGrammar, "md markdown mdx")
    add(dockerGrammar, "dockerfile docker containerfile")
    add(makeGrammar, "make makefile mk")
    return table
}()

private let specialFiles: [String: String] = [
    "dockerfile": "dockerfile", "containerfile": "dockerfile", "makefile": "makefile", "gnumakefile": "makefile",
    ".bashrc": "bash", ".zshrc": "zsh", ".profile": "sh", ".bash_profile": "bash", ".env": "env", ".gitconfig": "ini",
    "package.json": "json", "cargo.lock": "toml", "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby",
]

public enum SyntaxHighlighter {
    /// Beyond this size highlighting costs more than it helps; the text stays plain.
    public static let limit = 2_000_000

    public static func spans(_ text: String, language: String) -> [SyntaxSpan] {
        guard let grammar = SyntaxGrammar.named(language) else { return [] }
        return spans(text, grammar: grammar)
    }

    public static func spans(_ text: String, grammar: SyntaxGrammar) -> [SyntaxSpan] {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= limit else { return [] }
        var lexer = Lexer(units: units, grammar: grammar)
        lexer.run()
        return lexer.spans
    }
}

private func isIdentifierStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
private func isIdentifierPart(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
private func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == carriage }

private struct Lexer {
    let units: [UInt16]
    let grammar: SyntaxGrammar
    var spans: [SyntaxSpan] = []
    var i = 0
    /// Index of the first non-blank character on the current line.
    var lineStart = 0

    init(units: [UInt16], grammar: SyntaxGrammar) { self.units = units; self.grammar = grammar }

    mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
        guard end > start else { return }
        spans.append(SyntaxSpan(location: start, length: end - start, kind: kind))
    }

    func at(_ index: Int) -> UInt16? { index < units.count ? units[index] : nil }

    func matches(_ token: String, at index: Int) -> Bool {
        var k = index
        for unit in token.utf16 {
            guard k < units.count, units[k] == unit else { return false }
            k += 1
        }
        return true
    }

    func word(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<end], as: UTF16.self) }

    func endOfLine(from index: Int) -> Int {
        var k = index
        while k < units.count, units[k] != newline { k += 1 }
        return k
    }

    /// True when only spaces (and YAML list dashes) precede `index` on its line.
    func atLineStart(_ index: Int) -> Bool {
        var k = index - 1
        while k >= 0, units[k] != newline {
            if !isSpace(units[k]) && units[k] != 45 { return false }
            k -= 1
        }
        return true
    }

    func nextNonSpace(from index: Int) -> UInt16? {
        var k = index
        while k < units.count, isSpace(units[k]) { k += 1 }
        return at(k)
    }

    mutating func run() {
        switch grammar.mode {
        case .markup: runMarkup()
        case .markdown: runMarkdown()
        default: runCode()
        }
    }

    // MARK: Code, CSS and data formats

    mutating func runCode() {
        var braceDepth = 0
        while i < units.count {
            let c = units[i]
            if c == newline { i += 1; continue }
            if let block = grammar.blockComment, matches(block.open, at: i) {
                let start = i
                i += block.open.utf16.count
                while i < units.count, !matches(block.close, at: i) { i += 1 }
                i = min(units.count, i + block.close.utf16.count)
                emit(start, i, .comment); continue
            }
            if let prefix = grammar.lineComments.first(where: { matches($0, at: i) }) {
                // `#` starts a comment only at a word boundary, so `$#` and `a#b` stay code.
                let boundary = prefix != "#" || i == 0 || isSpace(units[i - 1]) || units[i - 1] == newline
                if boundary { let start = i; i = endOfLine(from: i); emit(start, i, .comment); continue }
            }
            if grammar.preprocessor, c == 35, atLineStart(i) {
                let start = i; i += 1
                while i < units.count, isIdentifierPart(units[i]) { i += 1 }
                emit(start, i, .decorator); continue
            }
            if grammar.rustAttributes, c == 35, at(i + 1) == 91 || (at(i + 1) == 33 && at(i + 2) == 91) {
                let start = i
                while i < units.count, units[i] != 93, units[i] != newline { i += 1 }
                i = min(units.count, i + 1)
                emit(start, i, .decorator); continue
            }
            if grammar.quotes.contains(c) || (grammar.characterLiterals && c == apostrophe) {
                if lexString(quoteUnit: c) { continue }
                i += 1; continue
            }
            if isDigit(c) || (c == 46 && at(i + 1).map(isDigit) == true), i == 0 || !isIdentifierPart(units[i - 1]) {
                let start = i
                i += 1
                while i < units.count {
                    let d = units[i]
                    if isIdentifierPart(d) || d == 46 { i += 1 }
                    else if (d == 43 || d == 45), i > start, units[i - 1] == 101 || units[i - 1] == 69, !matches("0x", at: start) { i += 1 }
                    else { break }
                }
                if grammar.mode == .css { while i < units.count, units[i] == 37 { i += 1 } }
                emit(start, i, .number); continue
            }
            if grammar.mode == .css {
                if c == 123 { braceDepth += 1 } else if c == 125 { braceDepth = max(0, braceDepth - 1) }
                if c == 35, braceDepth > 0 {
                    // Hex colours inside a rule.
                    let start = i; i += 1
                    while i < units.count, isIdentifierPart(units[i]) { i += 1 }
                    emit(start, i, .number); continue
                }
                if c == 64 {
                    let start = i; i += 1
                    while i < units.count, isIdentifierPart(units[i]) || units[i] == 45 { i += 1 }
                    emit(start, i, .keyword); continue
                }
                if isIdentifierStart(c) || c == 45 {
                    let start = i
                    while i < units.count, isIdentifierPart(units[i]) || units[i] == 45 { i += 1 }
                    if braceDepth > 0, nextNonSpace(from: i) == 58 { emit(start, i, .property) }
                    else if grammar.builtins.contains(word(start, i)) { emit(start, i, .builtin) }
                    else if braceDepth == 0 { emit(start, i, .function) }
                    else if at(i) == 40 { emit(start, i, .function) }
                    continue
                }
                i += 1; continue
            }
            if grammar.shellVariables, c == 36 {
                let start = i; i += 1
                if at(i) == 123 { while i < units.count, units[i] != 125, units[i] != newline { i += 1 }; i = min(units.count, i + 1) }
                else { while i < units.count, isIdentifierPart(units[i]) || (i == start + 1 && "@#?*!0123456789".utf16.contains(units[i])) { i += 1 } }
                if i > start + 1 { emit(start, i, .property) }
                continue
            }
            if grammar.decorators, c == 64, at(i + 1).map(isIdentifierStart) == true {
                let start = i; i += 1
                while i < units.count, isIdentifierPart(units[i]) || units[i] == 46 { i += 1 }
                emit(start, i, .decorator); continue
            }
            if isIdentifierStart(c) {
                let start = i
                while i < units.count, isIdentifierPart(units[i]) || (units[i] == 45 && grammar.keyValue) { i += 1 }
                // Ruby-style `defined?` and Rust macros like `println!`.
                let text = word(start, i)
                if grammar.keyValue {
                    if atLineStart(start), let next = nextNonSpace(from: i), next == 58 || next == 61 { emit(start, i, .property) }
                    else if grammar.builtins.contains(text) { emit(start, i, .builtin) }
                    continue
                }
                if grammar.keywords.contains(text) { emit(start, i, .keyword) }
                else if grammar.builtins.contains(text) { emit(start, i, .builtin) }
                else if at(i) == 33, grammar.rustAttributes { i += 1; emit(start, i, .function) }
                else if nextNonSpace(from: i) == 40 { emit(start, i, .function) }
                else if grammar.capitalizedTypes, units[start] >= 65, units[start] <= 90 { emit(start, i, .builtin) }
                continue
            }
            if grammar.keyValue, c == 91, atLineStart(i), grammar.lineComments.contains("#") || grammar.lineComments.contains(";") {
                // TOML and INI section headers.
                let start = i
                while i < units.count, units[i] != 93, units[i] != newline { i += 1 }
                i = min(units.count, i + 1)
                emit(start, i, .keyword); continue
            }
            i += 1
        }
    }

    /// Lexes a string starting at `i`; returns false when the quote does not open one.
    mutating func lexString(quoteUnit c: UInt16) -> Bool {
        let start = i
        if grammar.tripleQuotes, at(i + 1) == c, at(i + 2) == c {
            i += 3
            while i < units.count, !(units[i] == c && at(i + 1) == c && at(i + 2) == c) {
                i += units[i] == backslash ? 2 : 1
            }
            i = min(units.count, i + 3)
            emit(start, i, .string); return true
        }
        if c == apostrophe, grammar.characterLiterals {
            // 'a', '\n', '\u{1F600}': otherwise a Rust lifetime or a stray apostrophe.
            var k = i + 1
            if at(k) == backslash { k += 2 } else { k += 1 }
            while k < units.count, k - i <= 12, units[k] != apostrophe, units[k] != newline, units[i + 1] == backslash { k += 1 }
            guard at(k) == apostrophe else { return false }
            i = k + 1
            emit(start, i, .string); return true
        }
        let multiline = grammar.multilineQuotes.contains(c)
        i += 1
        while i < units.count {
            let d = units[i]
            if d == backslash, c != backtick || grammar.quotes.contains(backtick) { i += 2; continue }
            if d == c { i += 1; break }
            if d == newline, !multiline { break }
            i += 1
        }
        i = min(i, units.count)
        // A JSON key is a property, its value a string.
        if grammar.keyValue, nextNonSpace(from: i) == 58 { emit(start, i, .property) }
        else { emit(start, i, .string) }
        return true
    }

    // MARK: HTML and XML

    mutating func runMarkup() {
        while i < units.count {
            if matches("<!--", at: i) {
                let start = i
                while i < units.count, !matches("-->", at: i) { i += 1 }
                i = min(units.count, i + 3)
                emit(start, i, .comment); continue
            }
            if units[i] == 60, let next = at(i + 1), isIdentifierStart(next) || next == 47 || next == 33 || next == 63 {
                i += 1
                if units[i] == 47 || units[i] == 33 || units[i] == 63 { i += 1 }
                let nameStart = i
                while i < units.count, isIdentifierPart(units[i]) || units[i] == 45 || units[i] == 58 || units[i] == 46 { i += 1 }
                emit(nameStart, i, .keyword)
                // Attributes until the tag closes.
                while i < units.count, units[i] != 62 {
                    let d = units[i]
                    if d == quote || d == apostrophe {
                        let start = i; i += 1
                        while i < units.count, units[i] != d { i += 1 }
                        i = min(units.count, i + 1)
                        emit(start, i, .string)
                    } else if isIdentifierStart(d) {
                        let start = i
                        while i < units.count, isIdentifierPart(units[i]) || units[i] == 45 || units[i] == 58 || units[i] == 46 { i += 1 }
                        emit(start, i, .property)
                    } else { i += 1 }
                }
                i = min(units.count, i + 1)
                continue
            }
            if units[i] == 38 {
                // Character references: &amp; &#10;
                let start = i; i += 1
                while i < units.count, i - start < 12, isIdentifierPart(units[i]) || units[i] == 35 { i += 1 }
                if at(i) == 59 { i += 1; emit(start, i, .number) }
                continue
            }
            i += 1
        }
    }

    // MARK: Markdown source

    mutating func runMarkdown() {
        var fence = false
        while i < units.count {
            let lineEnd = endOfLine(from: i)
            var k = i
            while k < lineEnd, isSpace(units[k]) { k += 1 }
            if matches("```", at: k) || matches("~~~", at: k) {
                emit(i, lineEnd, .comment); fence.toggle()
            } else if fence {
                emit(i, lineEnd, .string)
            } else if at(k) == 35 {
                emit(i, lineEnd, .keyword)
            } else {
                if let marker = at(k), (marker == 45 || marker == 42 || marker == 43 || marker == 62), at(k + 1) == space { emit(k, k + 1, .decorator) }
                var j = k
                while j < lineEnd {
                    if units[j] == backtick {
                        let start = j; j += 1
                        while j < lineEnd, units[j] != backtick { j += 1 }
                        j = min(lineEnd, j + 1)
                        emit(start, j, .string); continue
                    }
                    if units[j] == 91 {
                        // [label](target): the target is a link.
                        var close = j + 1
                        while close < lineEnd, units[close] != 93 { close += 1 }
                        if close + 1 < lineEnd, units[close + 1] == 40 {
                            var end = close + 2
                            while end < lineEnd, units[end] != 41 { end += 1 }
                            emit(close + 1, min(lineEnd, end + 1), .function)
                            j = min(lineEnd, end + 1); continue
                        }
                    }
                    if (units[j] == 42 || units[j] == 95), at(j + 1) == units[j] {
                        let mark = units[j], start = j; j += 2
                        while j + 1 < lineEnd, !(units[j] == mark && units[j + 1] == mark) { j += 1 }
                        if j + 1 < lineEnd { j += 2; emit(start, j, .property) }
                        continue
                    }
                    j += 1
                }
            }
            i = lineEnd + 1
        }
    }
}
