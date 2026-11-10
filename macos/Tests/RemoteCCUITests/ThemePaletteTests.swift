#if canImport(AppKit)
import AppKit
import XCTest
@testable import RemoteCC
import RemoteCCCore

final class ThemePaletteTests: XCTestCase {
    private func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB)!
        func channel(_ x: CGFloat) -> CGFloat { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The settings page promises these ratios; keep every palette honest.
    func testEveryPaletteMeetsItsContrastRules() {
        for palette in ThemePalette.all {
            XCTAssertGreaterThanOrEqual(contrast(palette.text, palette.card), 7, palette.id)
            XCTAssertGreaterThanOrEqual(contrast(palette.textMuted, palette.card), 4.5, palette.id)
            XCTAssertGreaterThanOrEqual(contrast(palette.syntax.comment, palette.card), 4.5, palette.id)
            for kind in SyntaxKind.allCases where kind != .comment {
                XCTAssertGreaterThanOrEqual(contrast(palette.color(kind), palette.card), 5.5, "\(palette.id) \(kind)")
            }
            XCTAssertGreaterThanOrEqual(contrast(palette.text, palette.surface), 7, "\(palette.id) code background")
        }
    }

    func testDynamicColoursFollowAppearanceAndChosenPalette() {
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: ThemeStore.darkKey), defaults.string(forKey: ThemeStore.lightKey))
        defer { defaults.set(saved.0, forKey: ThemeStore.darkKey); defaults.set(saved.1, forKey: ThemeStore.lightKey) }
        defaults.set(ThemePalette.slate.id, forKey: ThemeStore.darkKey)
        defaults.set(ThemePalette.paper.id, forKey: ThemeStore.lightKey)
        let card = ThemeStore.dynamic { $0.card }
        func resolved(_ name: NSAppearance.Name) -> NSColor {
            var color = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { color = card.usingColorSpace(.sRGB)! }
            return color
        }
        func rgb(_ color: NSColor) -> [Int] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(resolved(.darkAqua)), rgb(ThemePalette.slate.card))
        XCTAssertEqual(rgb(resolved(.aqua)), rgb(ThemePalette.paper.card))
    }

    func testHighlightedCodeUsesPaletteColoursAndStaysPlainWhenUnknown() {
        let swift = CodeStyle.attributed("let x = 1", grammar: SyntaxGrammar.named("swift"))
        let keyword = swift.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let plain = swift.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(keyword); XCTAssertNotEqual(keyword, plain)
        let unknown = CodeStyle.attributed("let x = 1", grammar: nil)
        var runs = 0
        unknown.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: unknown.length)) { _, _, _ in runs += 1 }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(CodeStyle.gutter(lines: 12).string.components(separatedBy: "\n").count, 12)
    }
}
#endif
