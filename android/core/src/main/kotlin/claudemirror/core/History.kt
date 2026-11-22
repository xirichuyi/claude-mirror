package claudemirror.core

import java.time.Instant
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** A conversation Claude Code keeps on the server, whoever started it. */
@Serializable
data class RemoteConversation(
    val reference: String,
    val sessionId: String,
    val directory: String = "",
    val name: String = "",
    val updatedAt: Double = 0.0,
)

@Serializable
data class RemoteEntry(val path: String, val name: String, val directory: Boolean = false)

/** The folders of one remote directory. */
@Serializable
data class RemoteListing(val path: String, val parent: String = "", val entries: List<RemoteEntry> = emptyList())

private val commandName = Regex("<command-name>([^<]*)</command-name>")
private val commandArguments = Regex("<command-args>(.*?)</command-args>", RegexOption.DOT_MATCHES_ALL)
private val commandOutput = Regex("<local-command-stdout>(.*?)</local-command-stdout>", RegexOption.DOT_MATCHES_ALL)
private val reminder = Regex("<system-reminder>[\\s\\S]*?</system-reminder>\\s*")

/** Claude Code stores slash commands and their output inside XML-like tags. */
fun historyUserText(text: String): String {
    commandName.find(text)?.let { command ->
        val arguments = commandArguments.find(text)?.groupValues?.get(1)?.trim().orEmpty()
        return (command.groupValues[1].trim() + " " + arguments).trim()
    }
    commandOutput.find(text)?.let { return it.groupValues[1].trim() }
    return text.replace(reminder, "").trim()
}

/** A short title for a conversation found on the server. */
fun historyTitle(text: String): String =
    historyUserText(text).replace(Regex("<[^>]+>"), "").replace(Regex("\\s+"), " ").trim().take(80).ifEmpty { "未命名" }

/** A page of Claude Code's transcript: its messages, and the tool results whose calls are on the page before it. */
class HistoryPage(val messages: List<ChatMessage>, val loose: List<Block>)

fun historyMessages(records: List<JsonElement>): List<ChatMessage> = historyPage(records).messages

/** Gives tools the results that a later page of the transcript held for them. */
fun List<ChatMessage>.answered(results: List<Block>): List<ChatMessage> {
    if (results.isEmpty()) return this
    val byTool = results.associateBy { it.id }
    return map { message ->
        if (message.blocks?.any { it.type == "tool" && it.id in byTool } != true) message
        else message.copy(blocks = message.blocks.map { block ->
            val result = byTool[block.id]?.takeIf { block.type == "tool" } ?: return@map block
            block.copy(output = result.output, status = result.status ?: block.status)
        })
    }
}

/** Turns Claude Code's own transcript records into messages. */
fun historyPage(records: List<JsonElement>): HistoryPage {
    val messages = ArrayList<ChatMessage>()
    val loose = ArrayList<Block>()
    for (record in records) {
        val event = record.obj() ?: continue
        val id = event["uuid"].string() ?: UUID.randomUUID().toString()
        val time = event["timestamp"].string()?.let { runCatching { Instant.parse(it).toEpochMilli().toDouble() }.getOrNull() }
        val content = ((event["message"].obj()?.get("content")) as? JsonArray).orEmpty().mapNotNull { it.obj() }
        if (event["type"].string() == "user") {
            for (result in content) {
                if (result["type"].string() != "tool_result") continue
                val tool = result["tool_use_id"].string() ?: continue
                val output = result["content"].string() ?: (result["content"] as? JsonArray)?.joinToString("\n") { item ->
                    item.obj()?.get("text").string() ?: "[${item.obj()?.get("type").string() ?: "…"}]"
                }
                val answer = Block(type = "tool", id = tool, output = output, status = if (result["is_error"].truthy) "error" else null)
                val at = messages.indexOfLast { message -> message.blocks?.any { it.id == tool } == true }
                if (at < 0) loose += answer else messages[at] = listOf(messages[at]).answered(listOf(answer)).single()
            }
            val raw = content.filter { it["type"].string() == "text" }.mapNotNull { it["text"].string() }.joinToString("\n")
            val text = historyUserText(raw)
            if (text.isEmpty()) continue
            messages += if ("<local-command-stdout>" in raw && "<command-name>" !in raw) {
                ChatMessage(id = id, role = "assistant", blocks = listOf(Block(type = "text", text = text, format = "command")), createdAt = time)
            } else ChatMessage(id = id, role = "user", text = text, createdAt = time)
        } else {
            val blocks = content.mapNotNull { block ->
                when (block["type"].string()) {
                    "text" -> Block(type = "text", text = block["text"].string())
                    "thinking" -> Block(type = "thinking", text = block["thinking"].string())
                    "tool_use" -> Block(type = "tool", id = block["id"].string(), name = block["name"].string(), input = block["input"], status = "history")
                    else -> null
                }
            }
            val failed = event["isApiErrorMessage"].truthy || event["error"].string() != null
            val detail = blocks.filter { it.type == "text" }.mapNotNull { it.text }.joinToString("\n")
            messages += ChatMessage(id = id, role = "assistant", blocks = blocks, createdAt = time,
                error = if (failed) detail.ifEmpty { event["error"].string() ?: "请求失败" } else null)
        }
    }
    return HistoryPage(messages, loose)
}

internal fun JsonObject.list(key: String): List<JsonElement> = (this[key] as? JsonArray).orEmpty()
