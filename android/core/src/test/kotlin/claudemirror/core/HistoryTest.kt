package claudemirror.core

import kotlinx.serialization.json.JsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HistoryTest {
    private fun records(text: String) = (MirrorJson.parseToJsonElement(text) as JsonArray).toList()

    @Test fun `a transcript becomes prompts, replies and tools with their results`() {
        val messages = historyMessages(records("""[
            {"type":"user","uuid":"u1","timestamp":"2026-01-02T03:04:05.000Z","message":{"content":[{"type":"text","text":"<system-reminder>x</system-reminder>\nlist files"}]}},
            {"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}},
            {"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt","is_error":false}]}},
            {"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}},
            {"type":"user","uuid":"u3","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"denied","is_error":true}]}}
        ]"""))
        assertEquals(listOf("u1", "a1", "a2"), messages.map { it.id })
        assertEquals("list files", messages[0].text)
        assertEquals(1767323045000.0, messages[0].createdAt!!, 0.0)
        assertEquals(listOf("thinking", "text", "tool"), messages[1].blocks!!.map { it.type })
        assertEquals("a.txt", messages[1].blocks!![2].output)
        assertEquals("history", messages[1].blocks!![2].status)
        assertEquals("error", messages[2].blocks!![0].status)
    }

    @Test fun `slash commands and their output read as what was typed and what came back`() {
        val messages = historyMessages(records("""[
            {"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"<command-name>/compact</command-name><command-args>keep the plan</command-args>"}]}},
            {"type":"user","uuid":"u2","message":{"content":[{"type":"text","text":"<local-command-stdout>Compacted</local-command-stdout>"}]}},
            {"type":"assistant","uuid":"a1","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"overloaded"}]}}
        ]"""))
        assertEquals("/compact keep the plan", messages[0].text)
        assertEquals("assistant", messages[1].role)
        assertEquals("command", messages[1].blocks!![0].format)
        assertEquals("overloaded", messages[2].error)
        assertNull(messages[0].error)
    }

    @Test fun `titles drop the markup`() {
        assertEquals("fix the build", historyTitle("<system-reminder>r</system-reminder> fix\n the   build"))
        assertEquals("未命名", historyTitle("  "))
    }

    @Test fun `a result whose tool is on the page before waits for it`() {
        val later = historyPage(records("""[
            {"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"},{"type":"tool_result","tool_use_id":"t0","content":"no","is_error":true}]}},
            {"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"Done."}]}}
        ]"""))
        assertEquals(listOf("a2"), later.messages.map { it.id })
        assertEquals(listOf("t1", "t0"), later.loose.map { it.id })

        val earlier = historyPage(records("""[
            {"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t0","name":"Read","input":{}},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        ]""")).messages.answered(later.loose)
        assertEquals(listOf("error", "history"), earlier.single().blocks!!.map { it.status })
        assertEquals(listOf("no", "a.txt"), earlier.single().blocks!!.map { it.output })
    }
}
