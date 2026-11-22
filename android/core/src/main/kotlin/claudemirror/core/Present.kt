package claudemirror.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** What a tool call is, so the screen can show a command as a command and an edit as a change. */
enum class ToolKind { Command, Read, Write, Edit, Search, Web, Todo, Agent, Plan, Mcp, Other }

/** [title] says what is being done, [detail] is the command, file or search it is done to. */
data class ToolLook(val kind: ToolKind, val title: String, val detail: String)

private fun JsonElement?.field(key: String): String? = obj()?.get(key).string()?.takeIf { it.isNotBlank() }
private fun fileName(path: String?): String? = path?.trimEnd('/')?.substringAfterLast('/')?.takeIf { it.isNotEmpty() }
private fun JsonElement?.path(): String? = field("file_path") ?: field("notebook_path") ?: field("path")
private fun site(url: String?): String? = url?.substringAfter("://")?.substringBefore('/')?.takeIf { it.isNotEmpty() }

fun toolLook(name: String?, input: JsonElement?): ToolLook = when (name) {
    "Bash" -> ToolLook(ToolKind.Command, "运行命令", input.field("command").orEmpty())
    "BashOutput" -> ToolLook(ToolKind.Command, "读取命令输出", input.field("bash_id").orEmpty())
    "KillShell", "KillBash" -> ToolLook(ToolKind.Command, "结束后台命令", input.field("shell_id").orEmpty())
    "Read" -> ToolLook(ToolKind.Read, "读取", fileName(input.path()).orEmpty())
    "Write" -> ToolLook(ToolKind.Write, "写入", fileName(input.path()).orEmpty())
    "Edit", "MultiEdit", "NotebookEdit" -> ToolLook(ToolKind.Edit, "修改", fileName(input.path()).orEmpty())
    "Grep" -> ToolLook(ToolKind.Search, "搜索内容", input.field("pattern").orEmpty())
    "Glob" -> ToolLook(ToolKind.Search, "查找文件", input.field("pattern").orEmpty())
    "LS" -> ToolLook(ToolKind.Search, "列出目录", input.path().orEmpty())
    "WebFetch" -> ToolLook(ToolKind.Web, "打开网页", input.field("url").orEmpty())
    "WebSearch" -> ToolLook(ToolKind.Web, "搜索网页", input.field("query").orEmpty())
    "TodoWrite" -> todos(input).let { items -> ToolLook(ToolKind.Todo, "待办", "${items.count { it.status == "completed" }} / ${items.size} 已完成") }
    "Task", "Agent" -> ToolLook(ToolKind.Agent, "子代理", input.field("description") ?: input.field("prompt").orEmpty())
    "ExitPlanMode" -> ToolLook(ToolKind.Plan, "计划", "")
    null -> ToolLook(ToolKind.Other, "工具", "")
    else -> {
        val parts = name.split("__")
        if (parts.size >= 3 && parts[0] == "mcp") ToolLook(ToolKind.Mcp, parts.drop(2).joinToString("__"), parts[1])
        else ToolLook(
            ToolKind.Other, name,
            listOf("command", "file_path", "path", "pattern", "query", "url", "description", "prompt").firstNotNullOfOrNull { input.field(it) }.orEmpty(),
        )
    }
}

/** The question a request puts to the user, about its effect rather than the tool behind it. */
fun permissionHeadline(name: String?, input: JsonElement?): String {
    val file = fileName(input.path()) ?: "文件"
    return when (name) {
        "Bash" -> "运行这条命令？"
        "Edit", "MultiEdit", "NotebookEdit" -> "修改 $file？"
        "Write" -> "写入 $file？"
        "Read" -> "读取 $file？"
        "Glob", "Grep", "LS" -> "在项目中查找？"
        "WebFetch" -> "访问 ${site(input.field("url")) ?: "网页"}？"
        "WebSearch" -> "搜索网页？"
        "Task", "Agent" -> "启动子代理？"
        "ExitPlanMode" -> "按这个计划开始执行？"
        null -> "允许这项操作？"
        else -> toolLook(name, input).let { if (it.kind == ToolKind.Mcp) "使用 ${it.detail} 的 ${it.title}？" else "使用 $name？" }
    }
}

/** The server's own sentence about a request, unless it only repeats the tool name. */
fun permissionDetail(title: String?, description: String?): String? =
    listOf(description, title).firstOrNull { !it.isNullOrBlank() && !it.trim().startsWith("Claude 请求使用") }?.trim()

data class TodoItem(val text: String, val status: String)

fun todos(input: JsonElement?): List<TodoItem> = (input.obj()?.get("todos") as? JsonArray).orEmpty().mapNotNull { item ->
    val text = item.field("content") ?: item.field("activeForm") ?: return@mapNotNull null
    TodoItem(text, item.field("status") ?: "pending")
}

/** The text an edit takes out and the text it puts in, one pair per place changed. */
fun replacements(input: JsonElement?): List<Pair<String, String>> {
    val fields = input.obj() ?: return emptyList()
    val many = (fields["edits"] as? JsonArray)?.mapNotNull { it.obj() } ?: listOf(fields)
    return many.mapNotNull { edit ->
        val old = edit["old_string"].string() ?: edit["old_source"].string().orEmpty()
        val new = edit["new_string"].string() ?: edit["new_source"].string() ?: return@mapNotNull null
        old to new
    }
}

data class DiffLine(val sign: Char, val text: String)

/** A line-by-line comparison. Texts too long to compare cheaply are shown as all removed, then all added. */
fun diffLines(old: String, new: String): List<DiffLine> {
    val a = if (old.isEmpty()) emptyList() else old.lines()
    val b = if (new.isEmpty()) emptyList() else new.lines()
    if (a.size.toLong() * b.size > 250_000) return a.map { DiffLine('-', it) } + b.map { DiffLine('+', it) }
    // longest[i][j]: lines shared by a from i and b from j.
    val longest = Array(a.size + 1) { IntArray(b.size + 1) }
    for (i in a.indices.reversed()) for (j in b.indices.reversed()) {
        longest[i][j] = if (a[i] == b[j]) longest[i + 1][j + 1] + 1 else maxOf(longest[i + 1][j], longest[i][j + 1])
    }
    val lines = ArrayList<DiffLine>(a.size + b.size)
    var i = 0
    var j = 0
    while (i < a.size || j < b.size) when {
        i < a.size && j < b.size && a[i] == b[j] -> { lines += DiffLine(' ', a[i]); i++; j++ }
        j == b.size || (i < a.size && longest[i + 1][j] >= longest[i][j + 1]) -> lines += DiffLine('-', a[i++])
        else -> lines += DiffLine('+', b[j++])
    }
    return lines
}

/** What applying one of the server's suggested permission rules does, in words. */
data class RuleLine(val action: String, val scope: String, val widens: Boolean)

private val Scopes = mapOf(
    "session" to "本次", "localSettings" to "本项目", "projectSettings" to "本项目（共享）",
    "userSettings" to "所有项目", "cliArg" to "本次",
)
val PermissionModeNames = mapOf(
    "default" to "询问", "acceptEdits" to "自动编辑", "bypassPermissions" to "Full Access", "plan" to "计划", "dontAsk" to "不询问",
)

fun ruleLines(suggestions: JsonElement?): List<RuleLine> = (suggestions as? JsonArray).orEmpty().map { update ->
    val destination = update.field("destination").orEmpty()
    val scope = Scopes[destination] ?: destination
    val rules = (update.obj()?.get("rules") as? JsonArray).orEmpty().joinToString("、") { rule ->
        val tool = rule.field("toolName") ?: "工具"
        rule.field("ruleContent")?.let { "$tool($it)" } ?: tool
    }
    val directories = (update.obj()?.get("directories") as? JsonArray).orEmpty().mapNotNull { it.string() }.joinToString("、")
    val behavior = update.field("behavior")
    val verb = when (behavior) { "deny" -> "始终拒绝"; "ask" -> "始终询问"; else -> "始终允许" }
    when (update.field("type")) {
        "addRules" -> RuleLine("$verb $rules", scope, behavior == "allow")
        "replaceRules" -> RuleLine("改为$verb $rules", scope, behavior == "allow")
        "removeRules" -> RuleLine("移除 $rules", scope, behavior == "deny" || behavior == "ask")
        "setMode" -> update.field("mode").orEmpty().let { RuleLine("切到${PermissionModeNames[it] ?: it}", scope, it == "acceptEdits" || it == "bypassPermissions") }
        "addDirectories" -> RuleLine("目录 $directories", scope, true)
        "removeDirectories" -> RuleLine("移除目录 $directories", scope, false)
        else -> RuleLine(update.toString(), scope, true)
    }
}

/** The permission mode the server's suggestions switch the conversation to, if they do. */
fun suggestedMode(suggestions: JsonElement?): String? =
    (suggestions as? JsonArray).orEmpty().lastOrNull { it.field("type") == "setMode" }?.field("mode")

/** An error as the user should read it: Claude Code's internal diagnostic lines are left out. */
fun readableError(text: String?): String? =
    text?.lines()?.filterNot { Regex("""^\s*\[\w+_diagnostic]""").containsMatchIn(it) }?.joinToString("\n")?.trim()?.takeIf { it.isNotEmpty() }
