#if canImport(AppKit)
import AppKit
import SwiftUI
import RemoteCCCore

// Palette values and the derived-token rules are adapted from winc
// (https://github.com/DEEIX-AI/Winc), Copyright 2026 Chenyme and DEEIX AI, licensed under the
// Apache License 2.0 (Resources/ThirdParty/winc-LICENSE.txt). Modified: palettes renamed,
// translated to AppKit colours, and mapped onto this app's surfaces.
//
// The contrast rules come with them: body text at least 7:1 on its card, secondary text and
// comments at least 4.5:1, never pure black or white backgrounds, and syntax colours that share
// lightness and chroma in OKLCH so they stay distinguishable by lightness alone.

struct ThemePalette: Identifiable {
    struct Syntax { let text, keyword, builtin, string, number, comment, function, decorator, property: NSColor }

    let id: String
    let name: String
    let dark: Bool
    let frame, card, popup: NSColor
    let text, textMuted, textDim: NSColor
    let accent, accentFill, selection: NSColor
    let gutter, gutterActive: NSColor
    let error, warning: NSColor
    let gitModified, gitAdded, gitRemoved, gitConflict: NSColor
    let syntax: Syntax

    /// White on dark palettes, black on light ones; overlays are this colour at low opacity.
    var ink: NSColor { dark ? .white : .black }
    /// Inputs, code blocks and grouped rows sit slightly off the card.
    var surface: NSColor { mix(ink, card, dark ? 0.035 : 0.03) }
    var border: NSColor { mix(ink, card, dark ? 0.07 : 0.09) }
    var popupBorder: NSColor { ink.withAlphaComponent(dark ? 0.09 : 0.08) }
    var separator: NSColor { ink.withAlphaComponent(dark ? 0.06 : 0.07) }
    var hover: NSColor { ink.withAlphaComponent(dark ? 0.05 : 0.045) }
    var selected: NSColor { mix(accentFill, card, dark ? 0.32 : 0.16) }
    var selectedInactive: NSColor { mix(ink, card, dark ? 0.12 : 0.07) }
    var currentLine: NSColor { ink.withAlphaComponent(dark ? 0.03 : 0.025) }
    var shadow: NSColor { NSColor.black.withAlphaComponent(dark ? 0.5 : 0.14) }
    var scrim: NSColor { NSColor.black.withAlphaComponent(dark ? 0.4 : 0.08) }
    /// The tinted fill of a current tab; used for the user's own messages.
    var tint: NSColor { mix(accentFill, card, dark ? 0.24 : 0.1) }

    func color(_ kind: SyntaxKind?) -> NSColor {
        switch kind {
        case nil: return syntax.text
        case .keyword: return syntax.keyword
        case .builtin: return syntax.builtin
        case .string: return syntax.string
        case .number: return syntax.number
        case .comment: return syntax.comment
        case .function: return syntax.function
        case .decorator: return syntax.decorator
        case .property: return syntax.property
        }
    }
}

private func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

/// `a` laid over `b` at `amount`, in sRGB, as an opaque colour.
func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
    let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
    return NSColor(srgbRed: x.redComponent * amount + y.redComponent * (1 - amount),
                   green: x.greenComponent * amount + y.greenComponent * (1 - amount),
                   blue: x.blueComponent * amount + y.blueComponent * (1 - amount), alpha: 1)
}

private func syntaxColors(_ v: [UInt32]) -> ThemePalette.Syntax {
    ThemePalette.Syntax(text: hex(v[0]), keyword: hex(v[1]), builtin: hex(v[2]), string: hex(v[3]), number: hex(v[4]),
                        comment: hex(v[5]), function: hex(v[6]), decorator: hex(v[7]), property: hex(v[8]))
}

extension ThemePalette {
    /// Default dark: blue-grey charcoal.
    static let midnight = ThemePalette(
        id: "midnight", name: "深空", dark: true,
        frame: hex(0x15171C), card: hex(0x1B1E24), popup: hex(0x23272E),
        text: hex(0xD4D8DF), textMuted: hex(0x959CA8), textDim: hex(0x656C78),
        accent: hex(0x78AEF2), accentFill: hex(0x3D6FC4), selection: hex(0x2C4468),
        gutter: hex(0x4E5562), gutterActive: hex(0xA9B0BC), error: hex(0xF07F7F), warning: hex(0xE2BA6A),
        gitModified: hex(0x72A7EC), gitAdded: hex(0x5FBFA0), gitRemoved: hex(0xEB7F6C), gitConflict: hex(0xD898E0),
        syntax: syntaxColors([0xD4D8DF, 0xD7915C, 0x6DDAD6, 0x75B18B, 0xC28EC4, 0x7F8796, 0x6FB7F0, 0xE4CF7A, 0xF9AEB9]))

    /// Softer dark for lit rooms: one step lighter, lower contrast.
    static let slate = ThemePalette(
        id: "slate", name: "石板", dark: true,
        frame: hex(0x1E2127), card: hex(0x252930), popup: hex(0x2C3038),
        text: hex(0xCED3DB), textMuted: hex(0x99A0AC), textDim: hex(0x6C7380),
        accent: hex(0x7DB2F2), accentFill: hex(0x4472C2), selection: hex(0x35496B),
        gutter: hex(0x575E6B), gutterActive: hex(0xADB4BF), error: hex(0xF08585), warning: hex(0xE2BD70),
        gitModified: hex(0x78ABEC), gitAdded: hex(0x66C2A5), gitRemoved: hex(0xEC8573), gitConflict: hex(0xDA9DE2),
        syntax: syntaxColors([0xCED3DB, 0xDB9763, 0x72DCD8, 0x7DB892, 0xC895CA, 0x8A92A0, 0x76BCF2, 0xE6D282, 0xF9B3BE]))

    /// Default light: grey-tinted white.
    static let daylight = ThemePalette(
        id: "daylight", name: "明亮", dark: false,
        frame: hex(0xE9EBEF), card: hex(0xFBFBFC), popup: hex(0xFFFFFF),
        text: hex(0x24272E), textMuted: hex(0x5C6370), textDim: hex(0x9AA0AB),
        accent: hex(0x2B66D2), accentFill: hex(0x2B66D2), selection: hex(0xC9DCFA),
        gutter: hex(0xA4AAB5), gutterActive: hex(0x5A606B), error: hex(0xC2373A), warning: hex(0x9A6200),
        gitModified: hex(0x2B66D2), gitAdded: hex(0x16805F), gitRemoved: hex(0xC4432F), gitConflict: hex(0xA43F98),
        syntax: syntaxColors([0x24272E, 0xA43E3A, 0x156686, 0x1D691A, 0x58309D, 0x6B717D, 0x0A59CA, 0x574504, 0x7E2166]))

    /// Warm paper light.
    static let paper = ThemePalette(
        id: "paper", name: "米纸", dark: false,
        frame: hex(0xEAE6DE), card: hex(0xF7F4EE), popup: hex(0xFCFAF6),
        text: hex(0x2A2824), textMuted: hex(0x5F5A52), textDim: hex(0x9C968C),
        accent: hex(0x2A62C8), accentFill: hex(0x2A62C8), selection: hex(0xD6E0EE),
        gutter: hex(0xA9A398), gutterActive: hex(0x5F5A52), error: hex(0xBB3434), warning: hex(0x935C00),
        gitModified: hex(0x2A62C8), gitAdded: hex(0x157A5A), gitRemoved: hex(0xBC402C), gitConflict: hex(0x9D3B92),
        syntax: syntaxColors([0x2A2824, 0x9C3934, 0x12607E, 0x1B6318, 0x542D96, 0x6A665E, 0x0954C0, 0x524000, 0x781E5F]))

    static let all: [ThemePalette] = [.midnight, .slate, .daylight, .paper]
    static func named(_ id: String) -> ThemePalette? { all.first { $0.id == id } }
}

/// Appearance follows the system by default; each appearance has its own chosen palette.
enum ThemeStore {
    static let modeKey = "theme.mode", darkKey = "theme.dark", lightKey = "theme.light"
    enum Mode: String, CaseIterable { case system, light, dark }

    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .system }
    static var darkPalette: ThemePalette { ThemePalette.named(UserDefaults.standard.string(forKey: darkKey) ?? "") ?? .midnight }
    static var lightPalette: ThemePalette { ThemePalette.named(UserDefaults.standard.string(forKey: lightKey) ?? "") ?? .daylight }

    static func palette(for appearance: NSAppearance) -> ThemePalette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkPalette : lightPalette
    }

    /// Applies the chosen mode to the whole app; dynamic colours re-resolve on the next draw.
    @MainActor static func apply() {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// A colour that follows both the appearance and the palette chosen for it.
    static func dynamic(_ token: @escaping (ThemePalette) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in token(palette(for: appearance)) }
    }

    /// Syntax colours stay dynamic, so cached highlighted text follows theme changes. They are
    /// created once: equal source must render to equal attributed text, or views that compare
    /// it to skip updates would re-render every streamed code block.
    private static let syntaxColors: [String: NSColor] = {
        var table = ["": dynamic { $0.color(nil) }]
        for kind in SyntaxKind.allCases { table[kind.rawValue] = dynamic { $0.color(kind) } }
        return table
    }()
    static func syntaxColor(_ kind: SyntaxKind?) -> NSColor { syntaxColors[kind?.rawValue ?? ""]! }
}

/// AppKit-side tokens for attributed text; like the SwiftUI ones they resolve on every draw.
enum NSTheme {
    static let text = ThemeStore.dynamic { $0.text }
    static let textMuted = ThemeStore.dynamic { $0.textMuted }
    static let accent = ThemeStore.dynamic { $0.accent }
    static let border = ThemeStore.dynamic { $0.border }
    static let surface = ThemeStore.dynamic { $0.surface }
    static let card = ThemeStore.dynamic { $0.card }
    static let gutter = ThemeStore.dynamic { $0.gutter }
    static let gutterActive = ThemeStore.dynamic { $0.gutterActive }
    static let currentLine = ThemeStore.dynamic { $0.currentLine }
    static let selection = ThemeStore.dynamic { $0.selection }
}

/// Code is highlighted by RemoteCCCore's lexer and coloured with the active palette.
enum CodeStyle {
    static let fontSize: CGFloat = 12
    static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    /// Line height is the code size × 20/13, rounded to whole points so baselines stay crisp.
    static var lineHeight: CGFloat { (fontSize * 20 / 13).rounded() }

    /// Fixed line heights put the leftover space above the glyphs; split it evenly instead.
    static func baselineOffset(_ font: NSFont) -> CGFloat { max(0, (lineHeight - (font.ascender - font.descender)) / 2) }

    /// Right-aligned line numbers that line up with `attributed` text row for row.
    static func gutter(lines: Int, active: Int? = nil) -> NSAttributedString {
        let style = paragraph(); style.alignment = .right
        let result = NSMutableAttributedString(string: (1...max(1, lines)).map(String.init).joined(separator: "\n"),
            attributes: [.font: font, .foregroundColor: NSTheme.gutter, .paragraphStyle: style, .baselineOffset: baselineOffset(font)])
        if let active, active >= 1, active <= lines {
            let text = result.string as NSString
            var location = 0
            for _ in 1..<active { location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0))) }
            result.addAttribute(.foregroundColor, value: NSTheme.gutterActive, range: text.lineRange(for: NSRange(location: location, length: 0)))
        }
        return result
    }

    static func paragraph() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight; style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byClipping
        return style
    }

    /// Highlighted code; `grammar` nil leaves it plain. Colours are dynamic, never baked in.
    static func attributed(_ text: String, grammar: SyntaxGrammar?, font: NSFont = CodeStyle.font, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ThemeStore.syntaxColor(nil), .baselineOffset: baselineOffset(font)]
        attributes[.paragraphStyle] = paragraph ?? Self.paragraph()
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if let grammar {
            for span in SyntaxHighlighter.spans(text, grammar: grammar) {
                result.addAttribute(.foregroundColor, value: ThemeStore.syntaxColor(span.kind), range: span.range)
            }
        }
        return result
    }
}
#endif
