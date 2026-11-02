import Foundation

/// Presentation of Claude's own /usage output. Unrecognised details remain in raw text.
public struct UsageReport: Sendable {
    public struct Window: Sendable {
        public let title: String
        public let percent: Double
        public let reset: String?
    }
    public struct Activity: Sendable {
        public let title: String
        public let requests: String
        public let sessions: String
    }
    public let windows: [Window]
    public let activity: [Activity]
    public let raw: String

    public init?(_ text: String) {
        guard text.contains("Current session:"), text.contains("% used"),
              text.contains("Claude Code usage") || text.contains("Current week") else { return nil }
        func matches(_ pattern: String) -> [[String]] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                (1..<match.numberOfRanges).map { index in
                    Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                }
            }
        }
        windows = matches(#"(Current session|Current week(?:\s*\([^)]*\))?):\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets\s+([^\n]+?))?(?=\s*(?:Current |What's |Last |\n|$))"#).compactMap { row in
            guard let value = Double(row[1]), value >= 0, value <= 100 else { return nil }
            let title = row[0] == "Current session" ? "当前周期" : row[0] == "Current week (all models)" || row[0] == "Current week" ? "本周 · 全部模型" : row[0].replacingOccurrences(of: "Current week", with: "本周")
            return Window(title: title, percent: value, reset: row[2].isEmpty ? nil : row[2])
        }
        guard !windows.isEmpty else { return nil }
        activity = matches(#"Last (24h|7d)\s*·\s*([\d,]+) requests\s*·\s*([\d,]+) sessions"#).map {
            Activity(title: $0[0] == "24h" ? "过去 24 小时" : "过去 7 天", requests: $0[1], sessions: $0[2])
        }
        raw = text
    }
}
