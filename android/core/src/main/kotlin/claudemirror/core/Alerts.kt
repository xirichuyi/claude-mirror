package claudemirror.core

/** Something worth telling a user who is not looking at the app. */
sealed interface Alert {
    val session: ChatSession

    /** Claude waits for an answer. */
    data class Asked(override val session: ChatSession, val permission: PermissionRequest) : Alert
    data class Finished(override val session: ChatSession, val text: String) : Alert
    data class Failed(override val session: ChatSession, val reason: String) : Alert
}

/**
 * What happened between two states of the conversations. A reply the user stopped is not news to
 * them, and neither is one that the next queued message follows.
 */
fun alerts(before: List<ChatSession>, after: List<ChatSession>): List<Alert> {
    if (before === after) return emptyList()
    val earlier = before.associateBy { it.id }
    return after.flatMap { now ->
        val was = earlier[now.id]
        if (was == null || was === now) return@flatMap emptyList()
        val known = was.permissions.mapTo(HashSet()) { it.id }
        val asked = now.permissions.filter { it.id !in known }.map { Alert.Asked(now, it) }
        val ended = was.remoteTask != null && now.remoteTask == null && was.status != "stopping" && (now.queue.isEmpty() || now.queuePaused)
        val reply = now.messages.lastOrNull { it.role == "assistant" }
        asked + when {
            !ended -> emptyList()
            now.status == "idle" -> listOf(Alert.Finished(now, reply?.blocks.orEmpty().lastOrNull { it.type == "text" && !it.text.isNullOrBlank() }?.text?.trim().orEmpty()))
            else -> listOf(Alert.Failed(now, readableError(reply?.error).orEmpty()))
        }
    }
}
