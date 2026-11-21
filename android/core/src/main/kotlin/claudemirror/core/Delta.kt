package claudemirror.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/**
 * A watched task sends its first state in full and later ones as patches against the
 * previous version. Returns the full state the packet stands for.
 */
fun applyStateDelta(previous: JsonObject?, packet: JsonObject): JsonObject {
    if (!packet["delta"].truthy) return packet
    if (previous == null || previous["version"] != packet["base"]) throw RemoteException("远端状态版本不连续，请重新连接", confirmed = false)
    var state: JsonElement = previous
    for (patch in packet["patches"] as? JsonArray ?: JsonArray(emptyList())) {
        val path = (patch.obj()?.get("path") as? JsonArray)?.takeIf { it.isNotEmpty() } ?: throw invalid()
        state = patched(state, path, 0, patch as JsonObject)
    }
    if ((state as JsonObject)["version"] != packet["version"]) throw RemoteException("无效状态版本", confirmed = false)
    return state
}

private fun invalid() = RemoteException("无效状态增量", confirmed = false)

private fun appended(current: JsonElement?, patch: JsonObject): JsonElement {
    val text = current.string() ?: throw invalid()
    return JsonPrimitive(text + (patch["append"].string() ?: throw invalid()))
}

private fun patched(node: JsonElement, path: JsonArray, depth: Int, patch: JsonObject): JsonElement {
    val key = path[depth] as? JsonPrimitive ?: throw invalid()
    val last = depth == path.size - 1
    val append = patch["append"].takeIf { it != null && it != JsonNull } != null
    return when {
        node is JsonObject && key.isString -> {
            val fields = node.toMutableMap()
            val name = key.content
            if (!last) fields[name] = patched(fields[name] ?: throw invalid(), path, depth + 1, patch)
            else if (patch["remove"].truthy) fields.remove(name)
            else if (append) fields[name] = appended(fields[name], patch)
            else fields[name] = patch["value"] ?: JsonNull
            JsonObject(fields)
        }
        node is JsonArray && !key.isString -> {
            val index = key.doubleOrNull?.toInt() ?: throw invalid()
            if (index < 0 || index > node.size) throw invalid()
            val items = node.toMutableList()
            if (!last) {
                if (index == items.size) throw invalid()
                items[index] = patched(items[index], path, depth + 1, patch)
            } else {
                val value = if (append) appended(items.getOrNull(index), patch) else patch["value"] ?: JsonNull
                if (index == items.size) items.add(value) else items[index] = value
            }
            JsonArray(items)
        }
        else -> throw invalid()
    }
}
