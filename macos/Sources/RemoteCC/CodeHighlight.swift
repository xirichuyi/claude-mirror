#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Bounded, local token colouring. Unknown languages remain readable plain code.
enum CodeHighlight {
    private static let supported: Set<String> = ["swift", "js", "javascript", "ts", "typescript", "jsx", "tsx", "json", "python", "py", "sh", "bash", "zsh", "c", "cpp", "go", "rust", "java"]
    private static let regex = try? NSRegularExpression(pattern: #"(?<comment>//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/)|(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<number>\b\d+(?:\.\d+)?\b)|(?<keyword>\b(?:let|var|func|struct|class|enum|import|return|if|else|guard|for|while|await|async|try|throw|throws|const|function|export|from|def|in|with|as|true|false|null|nil|None|self|public|private|static|switch|case|break|continue|new)\b)"#)

    /// Colours tokens in place; other attributes (font, paragraph style) are left alone.
    static func apply(to text: NSMutableAttributedString, language: String) {
        guard supported.contains(language.lowercased()), text.length < 80_000, let regex else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
            let color: NSColor
            if match.range(withName: "comment").location != NSNotFound { color = .secondaryLabelColor }
            else if match.range(withName: "string").location != NSNotFound { color = .systemGreen }
            else if match.range(withName: "number").location != NSNotFound { color = .systemOrange }
            else { color = .systemPurple }
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

func highlightedCode(_ text: String, language: String) -> AttributedString {
    let result = NSMutableAttributedString(string: text)
    CodeHighlight.apply(to: result, language: language)
    return AttributedString(result)
}
#endif
