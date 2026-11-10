#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

/// Bounded, local token colouring with the active palette. Unknown languages remain plain code.
func highlightedCode(_ text: String, language: String) -> AttributedString {
    guard let grammar = SyntaxGrammar.named(language), text.utf16.count < 80_000 else { return AttributedString(text) }
    let result = NSMutableAttributedString(string: text)
    for span in SyntaxHighlighter.spans(text, grammar: grammar) {
        result.addAttribute(.foregroundColor, value: ThemeStore.syntaxColor(span.kind), range: span.range)
    }
    return AttributedString(result)
}
#endif
