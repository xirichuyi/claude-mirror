package claudemirror.app.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import claudemirror.core.Block
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.model.rememberMarkdownState
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

private val Pretty = Json { prettyPrint = true }

/** The part of a tool's input a person recognises it by: the command, the file, the search. */
fun toolSummary(input: JsonElement?): String {
    val fields = input as? JsonObject ?: return ""
    for (key in listOf("command", "file_path", "path", "pattern", "query", "url", "description", "prompt")) {
        val value = (fields[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (!value.isNullOrBlank()) return value
    }
    return ""
}

fun prettyJson(value: JsonElement?): String = value?.let { Pretty.encodeToString(JsonElement.serializer(), it) }.orEmpty()

@Composable
fun UserBubble(text: String, caption: String? = null, faded: Boolean = false) {
    Box(Modifier.fillMaxWidth().padding(start = 48.dp, end = 12.dp, top = 6.dp, bottom = 6.dp), contentAlignment = Alignment.CenterEnd) {
        Column(horizontalAlignment = Alignment.End) {
            Surface(
                color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = if (faded) 0.5f else 1f),
                shape = RoundedCornerShape(16.dp),
            ) {
                SelectionContainer {
                    Text(text, Modifier.widthIn(max = 520.dp).padding(horizontal = 14.dp, vertical = 10.dp), color = MaterialTheme.colorScheme.onPrimaryContainer)
                }
            }
            if (caption != null) Text(caption, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp, end = 4.dp))
        }
    }
}

@Composable
fun BlockView(block: Block) {
    when (block.type) {
        "text" -> if (!block.text.isNullOrBlank()) {
            // Laid out at full height from the first frame and while more text arrives; a block
            // that is empty until it has been parsed makes the list lose its place.
            val markdown = rememberMarkdownState(block.text!!, retainState = true, immediate = true)
            SelectionContainer { Markdown(markdown, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) }
        }
        "thinking" -> Thinking(block)
        "tool" -> ToolCard(block)
        "notice" -> Text(
            block.text.orEmpty(), Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
            color = if (block.level == "error") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        // A message the user inserted while this reply was being written.
        "user" -> UserBubble(
            block.text.orEmpty(),
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
private fun Thinking(block: Block) {
    var open by rememberSaveable(block.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().clickable { open = !open }.padding(horizontal = 16.dp, vertical = 4.dp).animateContentSize()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("思考过程", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (open) Text(block.text.orEmpty(), style = MaterialTheme.typography.bodySmall, fontStyle = FontStyle.Italic, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ToolCard(block: Block) {
    var open by rememberSaveable(block.id) { mutableStateOf(false) }
    val summary = block.summary?.takeIf { it.isNotBlank() } ?: toolSummary(block.input)
    OutlinedCard(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).clickable { open = !open }) {
        Column(Modifier.padding(12.dp).animateContentSize(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                when (block.status) {
                    "running" -> CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    "error" -> Icon(Icons.Filled.ErrorOutline, "失败", Modifier.size(18.dp), tint = MaterialTheme.colorScheme.error)
                    else -> Icon(Icons.Filled.Build, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(block.name ?: "工具", style = MaterialTheme.typography.labelLarge)
                Text(summary, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (open) {
                SelectionContainer {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(prettyJson(block.input).take(4000), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                        val output = block.output.orEmpty()
                        if (output.isNotBlank()) {
                            Text(
                                if (output.length > 6000) output.take(6000) + "\n…（其余 ${output.length - 6000} 个字符未显示）" else output,
                                style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                                color = if (block.status == "error") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        block.children?.forEach { child ->
                            Text("↳ " + (child.name ?: "工具") + "  " + toolSummary(child.input), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
}
