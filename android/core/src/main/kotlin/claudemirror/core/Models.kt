package claudemirror.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** The remote side owns most payload shapes, so unknown fields are ignored rather than rejected. */
val MirrorJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

/** [confirmed] is false when the remote side may still have carried out the request. */
class RemoteException(message: String, val confirmed: Boolean = true) : Exception(message)

class NodeMissingException : Exception("服务器上没有 Node.js，请先运行一键配置脚本")
class NodeOutdatedException(val version: String) : Exception("服务器上的 Node.js $version 太旧，需要 18.14 或更新版本")

@Serializable
enum class AuthMethod {
    @SerialName("password") Password,
    @SerialName("key") Key,
}

@Serializable
data class HostConfig(
    val id: String,
    val name: String = "",
    val user: String,
    val host: String,
    val port: Int = 22,
    val directory: String,
    val auth: AuthMethod = AuthMethod.Password,
    /** Fingerprint accepted on the first connection. A server presenting another key is refused. */
    val hostKey: String? = null,
) {
    val address: String get() = if (port == 22) "$user@$host" else "$user@$host:$port"
    val displayName: String get() = name.ifBlank { address }
}

@Serializable
data class ServerInfo(
    val home: String = "",
    val hostname: String? = null,
    val node: String? = null,
    val nodeSupported: Boolean = true,
    val claude: String? = null,
    val persistenceWarning: String? = null,
)

@Serializable
data class ChildTool(
    val id: String = "",
    val name: String? = null,
    val input: JsonElement? = null,
    val status: String? = null,
    val output: String? = null,
)

@Serializable
data class Block(
    val type: String,
    val text: String? = null,
    val id: String? = null,
    val name: String? = null,
    val input: JsonElement? = null,
    val status: String? = null,
    val output: String? = null,
    val summary: String? = null,
    val elapsed: Double? = null,
    val children: List<ChildTool>? = null,
    val agentText: String? = null,
    val level: String? = null,
    val format: String? = null,
    /** Set on a message inserted into a running reply until Claude has read it. */
    val pending: Boolean? = null,
    val cancelled: Boolean? = null,
)

@Serializable
data class ChatMessage(
    val id: String,
    val role: String,
    val text: String? = null,
    val blocks: List<Block>? = null,
    val createdAt: Double? = null,
    val error: String? = null,
    val interrupted: Boolean? = null,
    val activity: String? = null,
    val model: String? = null,
    val durationMs: Double? = null,
    val costUSD: Double? = null,
)

@Serializable
data class PermissionRequest(
    val id: String,
    val kind: String? = null,
    val name: String? = null,
    val input: JsonElement? = null,
    val title: String? = null,
    val description: String? = null,
    /** For kind "elicitation": what an MCP server asks the user. */
    val request: JsonElement? = null,
)

@Serializable
data class Preferences(
    val selectedModel: String? = null,
    val effort: String? = null,
    val permissionMode: String? = null,
    val executionUser: String? = null,
)

@Serializable
data class QueuedMessage(val id: String, val text: String)

/** One reply being produced: the worker process [id] is answering [messageId]. */
@Serializable
data class RemoteTask(
    val id: String,
    val prompt: String? = null,
    val version: Int = -1,
    val submitted: Boolean = false,
    val messageId: String? = null,
    /** True when the prompt goes to a worker that is already running instead of starting one. */
    val continuation: Boolean = false,
)

/** A worker that stays alive between replies and takes the next prompt directly. */
@Serializable
data class RemoteOwner(val id: String, val version: Int, val messageId: String? = null)

@Serializable
data class ContextUsage(val usedTokens: Double, val maxTokens: Double) {
    val label: String get() = compact(usedTokens) + " / " + compact(maxTokens)
    val fraction: Float get() = if (maxTokens > 0) (usedTokens / maxTokens).coerceIn(0.0, 1.0).toFloat() else 0f

    private fun compact(value: Double): String = when {
        value >= 1_000_000 -> trim(value / 1_000_000) + "M"
        value >= 1_000 -> trim(value / 1_000) + "k"
        else -> value.toLong().toString()
    }

    private fun trim(value: Double): String =
        if (value >= 100 || value % 1.0 < 0.05) value.toLong().toString() else "%.1f".format(java.util.Locale.ROOT, value)
}

@Serializable
data class ChatSession(
    val id: String,
    val hostId: String,
    val name: String = NEW_NAME,
    val directory: String,
    val createdAt: Long,
    val updatedAt: Long,
    val messages: List<ChatMessage> = emptyList(),
    val status: String = "idle",
    val permissions: List<PermissionRequest> = emptyList(),
    val preferences: Preferences = Preferences(),
    val remoteSessionId: String? = null,
    val remoteTask: RemoteTask? = null,
    val remoteOwner: RemoteOwner? = null,
    val transportError: String? = null,
    val model: String? = null,
    val context: ContextUsage? = null,
    val queue: List<QueuedMessage> = emptyList(),
    val queuePaused: Boolean = false,
    /** The queue was written for another machine; only the user's explicit go-ahead sends it. */
    val queueHeld: Boolean = false,
) {
    val isBusy: Boolean get() = status in BUSY

    companion object {
        const val NEW_NAME = "新对话"
        private val BUSY = setOf("connecting", "working", "permission", "stopping", "detached")
    }
}

internal val JsonElement?.truthy: Boolean
    get() = when (this) {
        null, JsonNull -> false
        is JsonPrimitive -> if (isString) true else booleanOrNull ?: true
        else -> true
    }

internal fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonElement?.obj(): JsonObject? = this as? JsonObject
