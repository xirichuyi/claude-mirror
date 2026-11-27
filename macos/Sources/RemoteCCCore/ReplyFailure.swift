import Foundation

/// Presentation only: preserve the original error and transcript for export and diagnostics.
public struct ReplyFailure: Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }

    public var isSafetyBlock: Bool {
        let value = raw.lowercased()
        return value.contains("safeguards flagged this session")
    }
    public var isQuotaProtection: Bool { raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("额度保护：") }
    public var title: String {
        if isSafetyBlock { return "请求被安全机制拦截" }
        if isQuotaProtection { return "额度保护 · 请求已暂停" }
        return "回复未完成"
    }
    public var summary: String {
        if isSafetyBlock { return "Claude 拒绝了本次请求" }
        if isQuotaProtection { return "已触发额度保护" }
        return raw.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "查看详情"
    }
    public func duplicates(_ block: Block) -> Bool {
        guard ["text", "notice"].contains(block.type), let text = block.text else { return false }
        return Self.normalized(text) == Self.normalized(raw)
    }
    private static func normalized(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("API Error:") { value = String(value.dropFirst("API Error:".count)) }
        return value.replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
