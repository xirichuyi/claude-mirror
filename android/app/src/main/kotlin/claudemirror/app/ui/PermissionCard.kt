package claudemirror.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import claudemirror.core.PermissionRequest
import claudemirror.core.permissionDetail
import claudemirror.core.permissionHeadline
import claudemirror.core.ruleLines
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

private val Refusal get() = buildJsonObject { put("allow", false); put("reason", "") }

/** Claude waits for this answer before it goes on. */
@Composable
fun PermissionCard(permission: PermissionRequest, onAnswer: (JsonObject) -> Unit) {
    val questions = ((permission.input as? JsonObject)?.get("questions") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
    Surface(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), color = palette.popup,
        shape = MaterialTheme.shapes.medium, border = BorderStroke(1.dp, palette.accent.copy(alpha = 0.55f)),
    ) {
        Column(Modifier.padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when {
                permission.kind == "elicitation" -> Elicitation(permission, onAnswer)
                questions.isNotEmpty() -> Questions(questions, onAnswer)
                else -> Approval(permission, onAnswer)
            }
        }
    }
}

@Composable
private fun Actions(refuse: String, accept: String?, enabled: Boolean = true, onRefuse: () -> Unit, onAccept: () -> Unit = {}) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onRefuse) { Text(refuse, color = palette.muted) }
        if (accept != null) Button(onClick = onAccept, enabled = enabled) { Text(accept) }
    }
}

@Composable
private fun Approval(permission: PermissionRequest, onAnswer: (JsonObject) -> Unit) {
    Text(permissionHeadline(permission.name, permission.input), style = MaterialTheme.typography.titleSmall, color = palette.text)
    permissionDetail(permission.title, permission.description)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.muted) }
    // In full: allowing covers the whole request, so none of it may be left out or cut off.
    ToolInput(permission.name, permission.input)
    val rules = remember(permission.suggestions) { ruleLines(permission.suggestions) }
    var keep by rememberSaveable(permission.id) { mutableStateOf(false) }
    if (rules.isNotEmpty()) Row(
        Modifier.fillMaxWidth().toggleable(keep, role = Role.Checkbox) { keep = it },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Checkbox(keep, null, Modifier.size(20.dp))
        Column {
            for (rule in rules) {
                Text(rule.action, style = MaterialTheme.typography.bodySmall, color = if (rule.widens) palette.warning else palette.text)
                Text(rule.scope, style = MaterialTheme.typography.labelSmall, color = palette.dim)
            }
        }
    }
    Actions(
        "拒绝", if (permission.name == "ExitPlanMode") "执行" else "允许", onRefuse = { onAnswer(Refusal) },
        onAccept = { onAnswer(buildJsonObject { put("allow", true); put("useSuggestedPermissions", keep && rules.isNotEmpty()) }) },
    )
}

@Composable
private fun Questions(questions: List<JsonObject>, onAnswer: (JsonObject) -> Unit) {
    // Saved, so answers outlive scrolling the card out of view and turning the screen.
    var chosen by rememberSaveable { mutableStateOf(mapOf<String, Set<String>>()) }
    var typed by rememberSaveable { mutableStateOf(mapOf<String, String>()) }
    fun answer(question: String): String = (chosen[question].orEmpty() + listOfNotNull(typed[question]?.trim()?.takeIf { it.isNotEmpty() })).joinToString(", ")
    for (item in questions) {
        val question = item.text("question") ?: continue
        val multiple = (item["multiSelect"] as? JsonPrimitive)?.content == "true"
        Text(question, style = MaterialTheme.typography.titleSmall, color = palette.text)
        Column {
            for (option in (item["options"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()) {
                val label = option.text("label") ?: continue
                val selected = label in chosen[question].orEmpty()
                val toggle = {
                    chosen = chosen + (question to if (multiple) { if (selected) chosen[question].orEmpty() - label else chosen[question].orEmpty() + label } else setOf(label))
                }
                Row(
                    Modifier.fillMaxWidth().selectable(selected, role = if (multiple) Role.Checkbox else Role.RadioButton, onClick = toggle).padding(vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (multiple) Checkbox(selected, null, Modifier.size(20.dp)) else RadioButton(selected, null, Modifier.size(20.dp))
                    Column {
                        Text(label, style = MaterialTheme.typography.bodyMedium, color = palette.text)
                        option.text("description")?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.muted) }
                    }
                }
            }
        }
        OutlinedTextField(
            typed[question].orEmpty(), { typed = typed + (question to it) }, Modifier.fillMaxWidth(),
            placeholder = { Text("其他", color = palette.dim) }, singleLine = true, textStyle = MaterialTheme.typography.bodyMedium,
        )
    }
    val names = questions.mapNotNull { it.text("question") }
    Actions("跳过", "提交", enabled = names.all { answer(it).isNotEmpty() }, onRefuse = { onAnswer(Refusal) }) {
        onAnswer(buildJsonObject {
            put("allow", true); put("useSuggestedPermissions", false)
            put("answers", buildJsonObject { names.forEach { put(it, answer(it)) } })
        })
    }
}

/** A form from an MCP server. It can be turned down here; filling it in takes the desktop app. */
@Composable
private fun Elicitation(permission: PermissionRequest, onAnswer: (JsonObject) -> Unit) {
    val request = permission.request as? JsonObject
    Text(request?.text("title") ?: request?.text("serverName") ?: "MCP", style = MaterialTheme.typography.titleSmall, color = palette.text)
    request?.text("message")?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = palette.text) }
    Text("请在电脑端填写", style = MaterialTheme.typography.bodySmall, color = palette.muted)
    Actions("拒绝", null, onRefuse = { onAnswer(buildJsonObject { put("interaction", buildJsonObject { put("action", "decline") }) }) })
}
