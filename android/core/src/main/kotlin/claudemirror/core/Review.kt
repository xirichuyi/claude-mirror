package claudemirror.core

/** One line of a unified diff with its numbers in the old and new file; a hunk header has neither. */
data class UnifiedLine(val sign: Char, val text: String, val old: Int?, val new: Int?)

private val HUNK = Regex("""^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@""")

/** `git diff` output as numbered lines, without the file headers. */
fun unifiedLines(diff: String): List<UnifiedLine> {
    val lines = ArrayList<UnifiedLine>()
    var old = 0
    var new = 0
    var inside = false
    for (raw in diff.split('\n')) {
        val line = raw.trimEnd('\r')
        val hunk = HUNK.find(line)
        when {
            hunk != null -> {
                inside = true; old = hunk.groupValues[1].toInt(); new = hunk.groupValues[2].toInt()
                lines += UnifiedLine('@', line, null, null)
            }
            line.startsWith("diff --git ") -> inside = false
            !inside || line.startsWith("\\") -> Unit
            line.startsWith("-") -> lines += UnifiedLine('-', line.drop(1), old++, null)
            line.startsWith("+") -> lines += UnifiedLine('+', line.drop(1), null, new++)
            line.startsWith(" ") -> lines += UnifiedLine(' ', line.drop(1), old++, new++)
        }
    }
    return lines
}

/** A note on one line of a diff, collected until the user sends them all to Claude at once. */
data class ReviewComment(val path: String, val line: Int, val removed: Boolean, val code: String, val text: String) {
    fun location(root: String?): String {
        val shown = relative(path, root)
        return if (removed) "$shown 删除前第 $line 行" else "$shown:$line"
    }

    companion object {
        /** The comment for a diff line, on its new side when it has one; null for hunk headers or empty text. */
        fun of(line: UnifiedLine, path: String, text: String): ReviewComment? {
            val body = text.trim()
            if (line.sign == '@' || body.isEmpty()) return null
            line.new?.let { return ReviewComment(path, it, false, line.text, body) }
            line.old?.let { return ReviewComment(path, it, true, line.text, body) }
            return null
        }

        fun relative(path: String, root: String?): String {
            if (root.isNullOrEmpty()) return path
            val prefix = if (root.endsWith('/')) root else "$root/"
            return if (path.startsWith(prefix)) path.removePrefix(prefix) else path
        }

        /** One message asking Claude to address every comment, in file and line order. */
        fun prompt(comments: List<ReviewComment>, root: String?): String {
            val lines = mutableListOf("请按下面的评论修改代码：")
            comments.sortedWith(compareBy<ReviewComment>({ it.path }, { it.line }, { if (it.removed) 0 else 1 })).forEachIndexed { index, comment ->
                lines += ""
                lines += "${index + 1}. `${comment.location(root)}`"
                val code = comment.code.trim(' ', '\t')
                if (code.isNotEmpty()) lines += "   > $code"
                comment.text.split('\n').forEach { lines += "   $it" }
            }
            return lines.joinToString("\n")
        }
    }
}
