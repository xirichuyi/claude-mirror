package claudemirror.core

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull

class ReviewTest {
    private val lines = unifiedLines("diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1,3 +1,3 @@\n keep\n-old line\n+new line\n-gone\n\\ No newline at end of file\n")

    @Test
    fun linesCarryTheirNumbers() {
        assertEquals(listOf('@', ' ', '-', '+', '-'), lines.map { it.sign })
        assertEquals(UnifiedLine(' ', "keep", 1, 1), lines[1])
        assertEquals(UnifiedLine('+', "new line", null, 2), lines[3])
        assertEquals(UnifiedLine('-', "gone", 3, null), lines[4])
    }

    @Test
    fun commentsPickTheNewSideOrTheDeletedLine() {
        assertEquals(ReviewComment("/p/a.ts", 2, false, "new line", "改名"), ReviewComment.of(lines[3], "/p/a.ts", " 改名 \n"))
        assertEquals(ReviewComment("/p/a.ts", 3, true, "gone", "为什么删"), ReviewComment.of(lines[4], "/p/a.ts", "为什么删"))
        assertNull(ReviewComment.of(lines[0], "/p/a.ts", "x"))
        assertNull(ReviewComment.of(lines[3], "/p/a.ts", " "))
    }

    @Test
    fun promptListsCommentsInFileOrder() {
        val text = ReviewComment.prompt(listOf(ReviewComment("/p/b.ts", 1, false, "b()", "第二"), ReviewComment("/p/a.ts", 9, true, "  gone()", "第一\n两行")), "/p")
        assertEquals("请按下面的评论修改代码：\n\n1. `a.ts 删除前第 9 行`\n   > gone()\n   第一\n   两行\n\n2. `b.ts:1`\n   > b()\n   第二", text)
        assertEquals("/other/x", ReviewComment.relative("/other/x", "/p"))
    }
}
