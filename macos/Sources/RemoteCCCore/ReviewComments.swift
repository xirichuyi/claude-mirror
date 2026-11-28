import Foundation

/// A note on one line of a diff, collected until the user sends them all to Claude at once.
public struct ReviewComment: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var line: Int
    /// The line is only in the old version: it was deleted.
    public var removed: Bool
    public var code: String
    public var text: String

    public init(id: UUID = UUID(), path: String, line: Int, removed: Bool = false, code: String, text: String) {
        self.id = id; self.path = path; self.line = line; self.removed = removed; self.code = code; self.text = text
    }

    /// The comment for a diff row, on its new side when it has one.
    public init?(row: SplitDiff.Row, path: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.kind != .hunk, !body.isEmpty else { return nil }
        if let number = row.right.number {
            self.init(path: path, line: number, code: row.right.text ?? "", text: body)
        } else if let number = row.left.number {
            self.init(path: path, line: number, removed: true, code: row.left.text ?? "", text: body)
        } else { return nil }
    }

    /// `src/a.ts:7`, or the old line number for a deleted line.
    public func location(root: String?) -> String {
        let shown = Self.relative(path, to: root)
        return removed ? "\(shown) 删除前第 \(line) 行" : "\(shown):\(line)"
    }

    public static func relative(_ path: String, to root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// One message asking Claude to address every comment, in file and line order.
    public static func prompt(_ comments: [ReviewComment], root: String?) -> String {
        let sorted = comments.sorted { ($0.path, $0.line, $0.removed ? 0 : 1) < ($1.path, $1.line, $1.removed ? 0 : 1) }
        var lines = ["请按下面的评论修改代码："]
        for (index, comment) in sorted.enumerated() {
            lines.append("")
            lines.append("\(index + 1). `\(comment.location(root: root))`")
            let code = comment.code.trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { lines.append("   > " + code) }
            for part in comment.text.components(separatedBy: "\n") { lines.append("   " + part) }
        }
        return lines.joined(separator: "\n")
    }
}
