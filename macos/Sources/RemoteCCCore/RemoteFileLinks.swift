import Foundation

/// Adds file actions to inline code without changing fenced examples or existing links.
public enum RemoteFileLinks {
    public static func markdown(_ source: String) -> String {
        let tokens = try! NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\([^\n]*?\)|!?\[[^\]\n]*\]\[[^\]\n]*\]|(`+)([^`\n]+)\1"#)
        var fence: (character: Character, count: Int)?
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.drop(while: { $0 == " " })
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                if count >= 3 {
                    if let current = fence {
                        if current.character == character && count >= current.count && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (character, count) }
                    return line
                }
            }
            guard fence == nil, !line.hasPrefix("    "), !line.hasPrefix("\t") else { return line }
            var result = line
            for match in tokens.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard match.range(at: 2).location != NSNotFound,
                      let content = Range(match.range(at: 2), in: line),
                      let whole = Range(match.range, in: result),
                      let url = destination(String(line[content])) else { continue }
                let label = String(result[whole])
                result.replaceSubrange(whole, with: "[\(label)](\(url))")
            }
            return result
        }.joined(separator: "\n")
    }

    private static func destination(_ raw: String) -> String? {
        guard remotePathReference(raw) != nil else { return nil }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~"))
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return "rcc-file:" + encoded
    }

    public static func reference(_ url: URL) -> (path: String, line: Int?)? {
        let raw: String
        switch url.scheme?.lowercased() {
        case "file": raw = url.path
        case "rcc-file": raw = String(url.absoluteString.dropFirst("rcc-file:".count)).removingPercentEncoding ?? ""
        case nil:
            raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            // Explicit Markdown links may name a relative folder without a slash or extension.
            guard !raw.isEmpty, !raw.hasPrefix("#"), !raw.contains("\n"), !raw.contains("\r") else { return nil }
            return remotePathReference(raw) ?? (raw, nil)
        default: return nil
        }
        return remotePathReference(raw)
    }
}
