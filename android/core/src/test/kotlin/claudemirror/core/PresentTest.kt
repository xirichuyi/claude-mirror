package claudemirror.core

import kotlinx.serialization.json.Json
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull

class PresentTest {
    private fun json(text: String) = Json.parseToJsonElement(text)

    @Test fun `a tool is described by what it does and what it does it to`() {
        assertEquals(ToolLook(ToolKind.Command, "运行命令", "npm test"), toolLook("Bash", json("""{"command":"npm test","description":"run"}""")))
        assertEquals(ToolLook(ToolKind.Edit, "修改", "App.kt"), toolLook("Edit", json("""{"file_path":"/srv/app/src/App.kt","old_string":"a","new_string":"b"}""")))
        assertEquals(ToolLook(ToolKind.Mcp, "create_issue", "github"), toolLook("mcp__github__create_issue", json("{}")))
        assertEquals(ToolLook(ToolKind.Todo, "待办", "1 / 2 已完成"), toolLook("TodoWrite", json("""{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"pending"}]}""")))
        assertEquals(ToolLook(ToolKind.Other, "Custom", "x"), toolLook("Custom", json("""{"query":"x"}""")))
        assertEquals(ToolLook(ToolKind.Other, "工具", ""), toolLook(null, null))
    }

    @Test fun `a request asks about its effect`() {
        assertEquals("运行这条命令？", permissionHeadline("Bash", json("""{"command":"ls"}""")))
        assertEquals("写入 a.txt？", permissionHeadline("Write", json("""{"file_path":"/tmp/a.txt"}""")))
        assertEquals("访问 example.com？", permissionHeadline("WebFetch", json("""{"url":"https://example.com/a/b"}""")))
        assertEquals("使用 github 的 create_issue？", permissionHeadline("mcp__github__create_issue", null))
        assertEquals("wait", permissionDetail("Claude 请求使用 Bash", "wait"))
        assertNull(permissionDetail("Claude 请求使用 Bash", " "))
    }

    @Test fun `an edit is compared line by line`() {
        assertEquals(listOf("a" to "b", "c" to "d"), replacements(json("""{"edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}""")))
        assertEquals(
            listOf(DiffLine(' ', "one"), DiffLine('-', "two"), DiffLine('+', "2"), DiffLine(' ', "three"), DiffLine('+', "four")),
            diffLines("one\ntwo\nthree", "one\n2\nthree\nfour"),
        )
        assertEquals(listOf(DiffLine('+', "new")), diffLines("", "new"))
    }

    @Test fun `suggested rules are put in words`() {
        val lines = ruleLines(json("""[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"},{"type":"setMode","mode":"plan","destination":"session"}]"""))
        assertEquals(listOf(RuleLine("自动允许 Bash(npm test:*)", "此项目的本地设置", true), RuleLine("权限模式切换为「计划模式」", "本次运行", false)), lines)
        assertEquals(emptyList<RuleLine>(), ruleLines(null))
    }

    @Test fun `internal diagnostics are not shown as errors`() {
        assertNull(readableError("[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"))
        assertEquals("API 出错", readableError("API 出错\n[ede_diagnostic] result_type=user"))
        assertNull(readableError(null))
    }
}
