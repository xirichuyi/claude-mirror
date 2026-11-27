package claudemirror.app.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FactCheck
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Timelapse
import androidx.compose.material.icons.filled.Build
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import claudemirror.core.ATTACHMENTS_ONLY
import claudemirror.core.Attachment
import claudemirror.core.Block
import claudemirror.core.ToolKind
import claudemirror.core.diffLines
import claudemirror.core.changes
import claudemirror.core.todos
import claudemirror.core.readableError
import claudemirror.core.toolLook
import com.mikepenz.markdown.compose.components.markdownComponents
import com.mikepenz.markdown.compose.elements.MarkdownCodeBlock
import com.mikepenz.markdown.compose.elements.MarkdownCodeFence
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import com.mikepenz.markdown.model.rememberMarkdownState
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

private val Pretty = Json { prettyPrint = true }

fun prettyJson(value: JsonElement?): String = value?.let { Pretty.encodeToString(JsonElement.serializer(), it) }.orEmpty()

private fun JsonElement?.text(key: String): String? = ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun clipped(text: String, limit: Int = 6000) = if (text.length > limit) text.take(limit) + "\n…（其余 ${text.length - limit} 个字符未显示）" else text

private val Pictures = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "svg")

fun fileIcon(name: String): ImageVector =
    if (name.substringAfterLast('.', "").lowercase() in Pictures) Icons.Filled.Image else Icons.AutoMirrored.Filled.InsertDriveFile

@Composable
fun UserBubble(text: String, files: List<Attachment> = emptyList(), caption: String? = null, faded: Boolean = false) {
    Box(Modifier.fillMaxWidth().padding(start = 48.dp, end = 16.dp, top = 10.dp, bottom = 10.dp), contentAlignment = Alignment.CenterEnd) {
        Column(horizontalAlignment = Alignment.End) {
            Surface(
                color = palette.selection.copy(alpha = if (faded) 0.5f else 1f),
                shape = RoundedCornerShape(20.dp),
            ) {
                val tint = palette.text.copy(alpha = if (faded) 0.7f else 1f)
                Column(Modifier.widthIn(max = 520.dp).padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    // The words a message of only files is given say nothing its files do not.
                    if (files.isEmpty() || text != ATTACHMENTS_ONLY) SelectionContainer { Text(text, color = tint) }
                    for (file in files) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(fileIcon(file.name), null, Modifier.size(16.dp), tint = palette.muted)
                        Text(file.name, style = MaterialTheme.typography.bodyMedium, color = tint, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                    }
                }
            }
            if (caption != null) Text(caption, style = MaterialTheme.typography.labelSmall, color = palette.muted, modifier = Modifier.padding(top = 3.dp, end = 4.dp))
        }
    }
}

@Composable
fun BlockView(block: Block) {
    when (block.type) {
        "text" -> if (!block.text.isNullOrBlank()) Prose(block.text!!)
        "thinking" -> Thinking(block)
        "tool" -> ToolRow(block)
        "notice" -> readableError(block.text)?.let { Notice(it, error = block.level == "error") }
        // A message the user inserted while this reply was being written.
        "user" -> UserBubble(
            block.text.orEmpty(), block.attachments.orEmpty(),
            caption = when {
                block.cancelled == true -> "已停止，未送达"
                block.pending == true -> "等待 Claude 读取…"
                else -> "已插入当前回复"
            },
            faded = block.cancelled == true || block.pending == true,
        )
    }
}

@Composable
fun Notice(text: String, error: Boolean) {
    if (text.isBlank()) return
    Row(Modifier.padding(horizontal = 20.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (error) Icon(Icons.Filled.ErrorOutline, null, Modifier.padding(top = 1.dp).size(15.dp), tint = palette.error)
        SelectionContainer { Text(text, style = MaterialTheme.typography.bodySmall, color = if (error) palette.error else palette.muted) }
    }
}

@Composable
private fun Prose(text: String) {
    val colors = palette
    val body = ProseStyle.copy(color = colors.text)
    val heading = body.copy(fontWeight = FontWeight.SemiBold)
    // Laid out at full height from the first frame and while more text arrives; a block
    // that is empty until it has been parsed makes the list lose its place.
    val markdown = rememberMarkdownState(text, retainState = true, immediate = true)
    SelectionContainer {
        Markdown(
            markdown,
            colors = markdownColor(text = colors.text, codeBackground = colors.card, inlineCodeBackground = colors.card, dividerColor = colors.line, tableBackground = colors.card),
            typography = markdownTypography(
                h1 = heading.copy(fontSize = 22.sp, lineHeight = 30.sp), h2 = heading.copy(fontSize = 19.sp, lineHeight = 28.sp),
                h3 = heading.copy(fontSize = 17.sp, lineHeight = 26.sp), h4 = heading, h5 = heading, h6 = heading,
                text = body, paragraph = body, ordered = body, bullet = body, list = body, quote = body.copy(color = colors.muted),
                code = CodeStyle, inlineCode = CodeStyle.copy(color = colors.syntax[0]),
            ),
            components = remember {
                markdownComponents(
                    codeBlock = { MarkdownCodeBlock(it.content, it.node, it.typography.code) { code, language, _ -> CodeBox(code, language) } },
                    codeFence = { MarkdownCodeFence(it.content, it.node, it.typography.code) { code, language, _ -> CodeBox(code, language) } },
                )
            },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
        )
    }
}

/** A collapsed line that opens to show the rest: used for tool calls and for Claude's thinking. */
@Composable
private fun Fold(
    key: String?, icon: @Composable () -> Unit, title: String, detail: String, mono: Boolean = false,
    content: (@Composable () -> Unit)?,
) {
    var open by rememberSaveable(key) { mutableStateOf(false) }
    val colors = palette
    // A quiet line between paragraphs, not a card: what Claude did reads as part of what it said.
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        Row(
            Modifier.fillMaxWidth().clickable(enabled = content != null, onClickLabel = if (open) "收起" else "展开") { open = !open }
                .heightIn(min = 36.dp).padding(horizontal = 20.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) { icon() }
            Text(title, style = MaterialTheme.typography.bodyMedium, color = colors.muted, maxLines = 1)
            Text(
                detail, Modifier.weight(1f, fill = false), style = if (mono) CodeStyle else MaterialTheme.typography.bodySmall,
                maxLines = 1, overflow = TextOverflow.Ellipsis, color = colors.muted,
            )
            if (content != null) Icon(if (open) Icons.Filled.ExpandMore else Icons.Filled.ChevronRight, null, Modifier.size(16.dp), tint = colors.dim)
        }
        if (open && content != null) {
            Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 2.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { content() }
        }
    }
}

@Composable
private fun Thinking(block: Block) {
    val text = block.text.orEmpty()
    Fold(
        block.id ?: text.take(40), icon = { Icon(Icons.Filled.Lightbulb, null, Modifier.size(16.dp), tint = palette.dim) },
        title = "思考", detail = text.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty().trim(),
        content = if (text.isBlank()) null else ({ SelectionContainer { Text(text, style = MaterialTheme.typography.bodyMedium, color = palette.muted) } }),
    )
}

fun ToolKind.icon(): ImageVector = when (this) {
    ToolKind.Command -> Icons.Filled.Terminal
    ToolKind.Read -> Icons.Filled.Description
    ToolKind.Write, ToolKind.Edit -> Icons.Filled.EditNote
    ToolKind.Search -> Icons.Filled.Search
    ToolKind.Web -> Icons.Filled.Language
    ToolKind.Todo, ToolKind.Plan -> Icons.AutoMirrored.Filled.FactCheck
    ToolKind.Agent -> Icons.Filled.Hub
    ToolKind.Mcp -> Icons.Filled.Extension
    ToolKind.Other -> Icons.Filled.Build
}

@Composable
private fun ToolRow(block: Block) {
    val look = remember(block.name, block.input) { toolLook(block.name, block.input) }
    Fold(
        block.id,
        icon = {
            when (block.status) {
                "running" -> CircularProgressIndicator(Modifier.size(15.dp), strokeWidth = 2.dp, color = palette.accent)
                "error" -> Icon(Icons.Filled.ErrorOutline, "失败", Modifier.size(17.dp), tint = palette.error)
                else -> Icon(look.kind.icon(), null, Modifier.size(16.dp), tint = palette.dim)
            }
        },
        title = look.title, detail = look.detail.lineSequence().firstOrNull().orEmpty(),
        mono = look.kind in setOf(ToolKind.Command, ToolKind.Search, ToolKind.Read, ToolKind.Write, ToolKind.Edit),
    ) {
        ToolInput(block.name, block.input)
        val output = block.output.orEmpty().trim('\n')
        if (output.isNotBlank()) CodeBox(clipped(output), "text", title = if (block.status == "error") "错误" else "输出", tint = if (block.status == "error") palette.error else palette.muted)
        block.summary?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.muted) }
        for (child in block.children.orEmpty()) {
            val inner = toolLook(child.name, child.input)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (child.status == "running") CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 2.dp, color = palette.accent)
                else Icon(if (child.status == "error") Icons.Filled.ErrorOutline else inner.kind.icon(), null, Modifier.size(15.dp), tint = if (child.status == "error") palette.error else palette.dim)
                Text(inner.title, style = MaterialTheme.typography.labelMedium, color = palette.text)
                Text(inner.detail.lineSequence().firstOrNull().orEmpty(), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = palette.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/**
 * Everything a tool was asked to do, shown as what it is: a command, a change to a file, a list of
 * tasks. Nothing is left out or cut short, because a request to approve covers all of it.
 */
@Composable
fun ToolInput(name: String?, input: JsonElement?) {
    val look = remember(name, input) { toolLook(name, input) }
    val fields = input as? JsonObject
    val path = input.text("file_path") ?: input.text("notebook_path") ?: input.text("path")
    val shown = mutableSetOf<String>()
    @Composable fun path() {
        if (path != null) SelectionContainer { Text(path, style = CodeStyle, color = palette.muted) }
        shown += listOf("file_path", "notebook_path", "path")
    }
    when (look.kind) {
        ToolKind.Command -> {
            input.text("description")?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.muted) }
            input.text("command")?.let { CodeBox(it, "bash", title = "命令") }
            shown += listOf("command", "description")
        }
        ToolKind.Write -> {
            path()
            input.text("content")?.let { content -> DiffBox(remember(content) { diffLines("", content) }); shown += "content" }
        }
        ToolKind.Edit -> {
            path()
            val pairs = remember(input) { changes(input) }
            for (change in pairs) {
                // Said with the change it belongs to: approving it rewrites more than the lines shown.
                if (change.everywhere) Text("全部替换", style = MaterialTheme.typography.labelMedium, color = palette.warning)
                DiffBox(remember(change) { diffLines(change.old, change.new) })
            }
            if (pairs.isNotEmpty()) shown += listOf("old_string", "new_string", "old_source", "new_source", "edits", "replace_all")
        }
        ToolKind.Todo -> {
            for (item in remember(input) { todos(input) }) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val done = item.status == "completed"
                Icon(
                    when (item.status) { "completed" -> Icons.Filled.CheckCircle; "in_progress" -> Icons.Filled.Timelapse; else -> Icons.Filled.RadioButtonUnchecked },
                    when (item.status) { "completed" -> "已完成"; "in_progress" -> "进行中"; else -> "未开始" },
                    Modifier.padding(top = 2.dp).size(16.dp), tint = when (item.status) { "completed" -> palette.added; "in_progress" -> palette.accent; else -> palette.dim },
                )
                Text(item.text, style = MaterialTheme.typography.bodyMedium, color = if (done) palette.muted else palette.text, textDecoration = if (done) TextDecoration.LineThrough else null)
            }
            shown += "todos"
        }
        ToolKind.Plan -> input.text("plan")?.let { Prose(it); shown += "plan" }
        else -> {}
    }
    // Whatever has no form of its own is still listed, by name.
    if (fields == null) {
        if (input != null) CodeBox(prettyJson(input), "json", title = "参数")
    } else for ((key, value) in fields) {
        if (key in shown) continue
        Column {
            Text(key, style = MaterialTheme.typography.labelSmall, color = palette.muted)
            SelectionContainer { Text(input.text(key) ?: prettyJson(value), style = if (value is JsonPrimitive && value.isString) MaterialTheme.typography.bodyMedium else CodeStyle, color = palette.text) }
        }
    }
}
