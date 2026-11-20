package claudemirror.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import claudemirror.core.PermissionRequest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

/** Claude waits for this answer before it goes on. */
@Composable
fun PermissionCard(permission: PermissionRequest, onAnswer: (JsonObject) -> Unit) {
    val questions = ((permission.input as? JsonObject)?.get("questions") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
    ElevatedCard(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Column(Modifier.padding(16.dp).heightIn(max = 420.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when {
                permission.kind == "elicitation" -> Elicitation(permission, onAnswer)
                questions.isNotEmpty() -> Questions(questions, onAnswer)
                else -> Approval(permission, onAnswer)
            }
        }
    }
}

@Composable
private fun Approval(permission: PermissionRequest, onAnswer: (JsonObject) -> Unit) {
    Text(permission.title ?: "Claude 想使用 ${permission.name ?: "工具"}", style = MaterialTheme.typography.titleSmall)
    permission.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    // Every field in full: allowing covers the whole request, so none of it may be left out or cut off.
    val fields = permission.input as? JsonObject
    if (fields == null) {
        if (permission.input != null) Text(prettyJson(permission.input), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
    } else for ((name, value) in fields) {
        if (fields.size > 1) Text(name, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(fields.text(name) ?: prettyJson(value), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        OutlinedButton(onClick = { onAnswer(buildJsonObject { put("allow", false); put("reason", "") }) }) { Text("拒绝") }
        Button(onClick = { onAnswer(buildJsonObject { put("allow", true); put("useSuggestedPermissions", false) }) }) { Text("允许") }
    }
}

@Composable
private fun Questions(questions: List<JsonObject>, onAnswer: (JsonObject) -> Unit) {
    val chosen = remember { mutableStateMapOf<String, Set<String>>() }
    val typed = remember { mutableStateMapOf<String, String>() }
    fun answer(question: String): String = (chosen[question].orEmpty() + listOfNotNull(typed[question]?.trim()?.takeIf { it.isNotEmpty() })).joinToString(", ")
    Text("Claude 想问你", style = MaterialTheme.typography.titleSmall)
    for (item in questions) {
        val question = item.text("question") ?: continue
        val multiple = (item["multiSelect"] as? JsonPrimitive)?.content == "true"
        Text(question + if (multiple) "（可多选）" else "", style = MaterialTheme.typography.bodyMedium)
        for (option in (item["options"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()) {
            val label = option.text("label") ?: continue
            val selected = label in chosen[question].orEmpty()
            val toggle = {
                chosen[question] = if (multiple) { if (selected) chosen[question].orEmpty() - label else chosen[question].orEmpty() + label } else setOf(label)
            }
            Row(Modifier.fillMaxWidth().selectable(selected, onClick = toggle), verticalAlignment = Alignment.CenterVertically) {
                if (multiple) Checkbox(selected, { toggle() }) else RadioButton(selected, toggle)
                Column {
                    Text(label)
                    option.text("description")?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        }
        OutlinedTextField(typed[question].orEmpty(), { typed[question] = it }, Modifier.fillMaxWidth(), label = { Text("其他回答") }, singleLine = true)
    }
    val names = questions.mapNotNull { it.text("question") }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        OutlinedButton(onClick = { onAnswer(buildJsonObject { put("allow", false); put("reason", "") }) }) { Text("不回答") }
        Button(
            enabled = names.all { answer(it).isNotEmpty() },
            onClick = {
                onAnswer(buildJsonObject {
                    put("allow", true); put("useSuggestedPermissions", false)
                    put("answers", buildJsonObject { names.forEach { put(it, answer(it)) } })
                })
            },
        ) { Text("提交") }
    }
}

@Composable
private fun Elicitation(permission: PermissionRequest, onAnswer: (JsonObject) -> Unit) {
    val request = permission.request as? JsonObject
    Text(request?.text("title") ?: "需要你的输入", style = MaterialTheme.typography.titleSmall)
    request?.text("serverName")?.let { Text("来自 MCP 服务 $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    request?.text("message")?.let { Text(it) }
    Text("手机端暂不支持填写这类表单，可以拒绝，或在电脑上的 Claude Mirror 里填写。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        OutlinedButton(onClick = { onAnswer(buildJsonObject { put("interaction", buildJsonObject { put("action", "decline") }) }) }) { Text("拒绝") }
    }
}
