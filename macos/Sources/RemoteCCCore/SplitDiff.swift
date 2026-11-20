import Foundation

/// A unified diff laid out side by side: old text on the left, new on the right, row for row.
public struct SplitDiff: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed, modified, hunk }

    public struct Side: Sendable, Equatable {
        /// nil marks a filler row where this side has no line.
        public var text: String?
        public var number: Int?
        /// UTF-16 range of the changed part of a modified line.
        public var changed: NSRange?
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: Kind
        public var left: Side
        public var right: Side
        /// Index into `changes` for rows inside a change block.
        public var change: Int?
    }

    public var rows: [Row] = []
    /// Row ranges of each block of consecutive changes, in order.
    public var changes: [Range<Int>] = []
    public var added = 0
    public var removed = 0

    public init(_ unified: String) {
        var oldLine = 0, newLine = 0
        var inHunk = false
        var removedLines: [String] = [], addedLines: [String] = []

        func append(_ kind: Kind, _ left: Side, _ right: Side, change: Int? = nil) {
            rows.append(Row(id: rows.count, kind: kind, left: left, right: right, change: change))
        }
        func flush() {
            guard !removedLines.isEmpty || !addedLines.isEmpty else { return }
            let start = rows.count, index = changes.count
            for k in 0..<max(removedLines.count, addedLines.count) {
                let old = k < removedLines.count ? removedLines[k] : nil
                let new = k < addedLines.count ? addedLines[k] : nil
                var left = Side(text: old, number: old == nil ? nil : oldLine + 1)
                var right = Side(text: new, number: new == nil ? nil : newLine + 1)
                if old != nil { oldLine += 1 }
                if new != nil { newLine += 1 }
                let kind: Kind
                if let old, let new {
                    kind = .modified
                    (left.changed, right.changed) = SplitDiff.changedRanges(old, new)
                } else { kind = old == nil ? .added : .removed }
                append(kind, left, right, change: index)
            }
            changes.append(start..<rows.count)
            removed += removedLines.count; added += addedLines.count
            removedLines = []; addedLines = []
        }

        for line in unified.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git") { flush(); inHunk = false }
            if line.hasPrefix("\\ No newline") { continue }
            if !inHunk, ["diff --git", "index ", "--- ", "+++ ", "new file", "deleted file", "similarity", "rename ", "\\ No newline"].contains(where: line.hasPrefix) { continue }
            if line.hasPrefix("@@") {
                flush()
                inHunk = true
                if let (old, new) = SplitDiff.hunkStarts(line) { oldLine = old - 1; newLine = new - 1 }
                append(.hunk, Side(text: line), Side(text: line))
            } else if line.hasPrefix("-") {
                // A deletion after additions starts a new pairing within the block.
                if !addedLines.isEmpty && removedLines.count >= addedLines.count { flush() }
                removedLines.append(String(line.dropFirst()))
            } else if line.hasPrefix("+") {
                addedLines.append(String(line.dropFirst()))
            } else if !line.isEmpty || !rows.isEmpty {
                flush()
                if line.isEmpty { continue } // The trailing newline of the patch.
                let text = String(line.dropFirst())
                oldLine += 1; newLine += 1
                append(.context, Side(text: text, number: oldLine), Side(text: text, number: newLine))
            }
        }
        flush()
    }

    /// `@@ -12,7 +12,9 @@` → (12, 12).
    static func hunkStarts(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let oldText = parts[1].dropFirst().split(separator: ",").first,
              let newText = parts[2].dropFirst().split(separator: ",").first,
              let old = Int(oldText), let new = Int(newText) else { return nil }
        return (old, new)
    }

    /// The differing middle of two lines after their common prefix and suffix, per side.
    static func changedRanges(_ old: String, _ new: String) -> (NSRange?, NSRange?) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let left = a.count - prefix - suffix, right = b.count - prefix - suffix
        return (left > 0 ? NSRange(location: prefix, length: left) : nil, right > 0 ? NSRange(location: prefix, length: right) : nil)
    }
}
