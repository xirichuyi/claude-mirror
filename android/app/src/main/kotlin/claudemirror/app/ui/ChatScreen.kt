package claudemirror.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.platform.LocalConfiguration
import claudemirror.core.modelName
import claudemirror.core.readableError
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.ui.input.key.onPreInterceptKeyBeforeSoftKeyboard
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.ChatSession
import claudemirror.core.ConnectionState
import kotlinx.serialization.json.JsonObject

private val PermissionModes = listOf(null to "询问", "acceptEdits" to "自动编辑", "plan" to "计划", "bypassPermissions" to "Full Access")
private val Efforts = mapOf("low" to "低", "medium" to "中", "high" to "高", "xhigh" to "极高", "max" to "最大")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(model: AppModel, sessionId: String, snackbar: SnackbarHostState, onBack: () -> Unit) {
    val sessions by model.sessions.collectAsStateWithLifecycle()
    val session = sessions.firstOrNull { it.id == sessionId }
    if (session == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val connections by model.connections.collectAsStateWithLifecycle()
    var draft by rememberSaveable(sessionId) { mutableStateOf("") }
    val online = connections[session.hostId] is ConnectionState.Connected
    LaunchedEffect(sessionId, online) { if (online) model.refresh(sessionId) }

    // A phone on its side with its keyboard up: the title gives its room to the conversation.
    val screen = LocalConfiguration.current
    val tight = screen.screenWidthDp > screen.screenHeightDp && with(LocalDensity.current) { screen.screenHeightDp.dp - WindowInsets.ime.getBottom(this).toDp() } < 300.dp
    Scaffold(
        topBar = {
            if (!tight) TopAppBar(
                title = {
                    Column {
                        Text(session.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        (session.statusLabel() ?: session.model?.let(::modelName))?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
            )
        },
        snackbarHost = { Snackbar(snackbar) },
    ) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
            // What is left of a phone on its side, or under its keyboard: the composer takes one line.
            val compact = maxHeight < 320.dp
            val wide = maxWidth >= 600.dp
            // Larger type needs the room a wider window has.
            val narrow = maxWidth < 380.dp * LocalDensity.current.fontScale
            val queueRoom = minOf(maxHeight / 4, 144.dp)
            Column(Modifier.fillMaxSize()) {
                if (session.status == "detached" || session.transportError != null) {
                    val host = model.host(session.hostId)
                    Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
                        Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                // Why a connection could not be made is worth reading; how an open one broke is not.
                                (connections[session.hostId] as? ConnectionState.Failed)?.error?.message ?: "已断开",
                                Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall,
                            )
                            if (host != null) TextButton(onClick = { model.reconnect(host) }) { Text("重连") }
                        }
                    }
                }
                // The composer keeps its place below, however short the window and however much waits above it.
                Column(Modifier.weight(1f)) {
                    Transcript(session, Modifier.weight(1f), onEarlier = { model.loadEarlier(sessionId) }) { permission, answer -> model.respond(sessionId, permission, answer) }
                    // Editing a queued message must not throw away what is already being written.
                    Queue(session, model, queueRoom, onEdit = { item -> draft = if (draft.isBlank()) item else draft.trimEnd() + "\n" + item })
                }
                // Under a keyboard there is no room left for the request's card, so its answer comes down here.
                if (compact) session.permissions.firstOrNull()?.let { permission -> PermissionBar(permission) { answer -> model.respond(sessionId, permission.id, answer) } }
                Composer(
                    session, model, draft, compact, wide, narrow, onDraft = { draft = it },
                    onSend = { steer -> if (model.submit(sessionId, draft, steer)) draft = "" },
                    onStop = { model.stop(sessionId) },
                )
            }
        }
    }
}

@Composable
private fun Transcript(session: ChatSession, modifier: Modifier, onEarlier: () -> Unit, onAnswer: (permission: String, JsonObject) -> Unit) {
    val list = rememberLazyListState()
    // One row per block, so a long reply only redraws the part that is still being written.
    val rows = remember(session.messages) {
        session.messages.flatMap { message ->
            if (message.role == "user") listOf(Triple(message.id, message, -1))
            else message.blocks.orEmpty().indices.map { Triple(message.id + ":" + it, message, it) } + Triple(message.id + ":end", message, -2)
        }
    }
    val last = session.messages.lastOrNull()
    if (rows.isEmpty() && session.permissions.isEmpty()) {
        Box(modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
            Text("在 ${session.directory} 里开始对话。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    // Whether the view keeps up with the reply. Only the reader's own scrolling changes it:
    // text arriving, the keyboard opening or the screen turning must not end it.
    var following by rememberSaveable { mutableStateOf(true) }
    val reader = remember(list) {
        object : NestedScrollConnection {
            // Only gestures come through here; the scrolling done below does not.
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (consumed.y > 0f) following = false else if (!list.canScrollForward) following = true
                return Offset.Zero
            }
        }
    }
    val end by rememberUpdatedState(rows.size)
    LaunchedEffect(list) {
        // Whatever makes the list longer than the window, the end comes back into view. A reader
        // already past it, part way down a request taller than the window, is not taken back up.
        fun behind() = following && list.canScrollForward && !list.isScrollInProgress && list.firstVisibleItemIndex < end
        snapshotFlow { behind() }.collect {
            var place = -1 to -1
            while (behind()) {
                list.scrollToItem(end)
                if (place == list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset) break
                place = list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset
                withFrameNanos { }
            }
        }
    }
    // A request Claude is waiting on is brought into view, wherever the reader was, and stays there.
    val asked = session.permissions.firstOrNull()?.id
    LaunchedEffect(asked) {
        if (asked != null) { following = true; list.scrollToItem(rows.size) }
    }
    Column(modifier) {
    // A conversation brought over from the server shows its latest part; the rest comes on request.
    if (session.historyBefore != null && !list.canScrollBackward) {
        TextButton(onClick = onEarlier, Modifier.align(Alignment.CenterHorizontally)) { Text("更早", color = palette.muted) }
    }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().nestedScroll(reader), state = list) {
        items(rows.size, key = { rows[it].first }) { index ->
            val (_, message, part) = rows[index]
            when (part) {
                -1 -> UserBubble(message.text.orEmpty())
                -2 -> Column(Modifier.padding(horizontal = 16.dp)) {
                    readableError(message.error)?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    if (message.interrupted == true) Text("已停止", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
                }
                else -> BlockView(message.blocks!![part])
            }
        }
        item(key = "status") {
            // A pending request is shown by its own card.
            if (session.isBusy && session.status != "permission") {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (session.status != "detached") CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(
                        if (session.status == "working") last?.activity?.takeIf { it.isNotBlank() } ?: "Claude 正在回复…" else session.statusLabel().orEmpty(),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        // In the list rather than pinned over it: a long command must not push the reply or the composer off screen.
        items(session.permissions, key = { "permission:" + it.id }) { permission ->
            PermissionCard(permission) { answer -> onAnswer(permission.id, answer) }
        }
    }
    }
}

/** Messages waiting for the current reply to end. Each can go into the reply now, back to the editor, or away. */
@Composable
private fun Queue(session: ChatSession, model: AppModel, room: Dp, onEdit: (String) -> Unit) {
    if (session.queue.isEmpty()) return
    HorizontalDivider()
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val waiting = (session.queuePaused || session.queueHeld) && session.remoteTask == null
            Text(
                when {
                    session.queueHeld -> "排队 ${session.queue.size} · 服务器已更改"
                    waiting -> "排队 ${session.queue.size} · 已暂停"
                    else -> "排队 ${session.queue.size}"
                },
                Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (waiting) TextButton(onClick = { model.resumeQueue(session.id) }) { Text("继续") }
            TextButton(onClick = { model.clearQueue(session.id) }) { Text("清空") }
        }
        Column(Modifier.heightIn(max = room).verticalScroll(rememberScrollState())) {
            for (item in session.queue) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.text, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                    if (session.remoteTask != null) IconButton(onClick = { model.steer(session.id, item.id) }) { Icon(Icons.Filled.Bolt, "插队") }
                    IconButton(onClick = { model.cancelQueued(session.id, item.id); onEdit(item.text) }) { Icon(Icons.Filled.Edit, "编辑") }
                    IconButton(onClick = { model.cancelQueued(session.id, item.id) }) { Icon(Icons.Filled.Close, "移除") }
                }
            }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Composer(
    session: ChatSession, model: AppModel, draft: String, compact: Boolean, wide: Boolean, narrow: Boolean,
    onDraft: (String) -> Unit, onSend: (steer: Boolean) -> Unit, onStop: () -> Unit,
) {
    val replying = session.remoteTask != null
    val ready = draft.isNotBlank()
    val actions: @Composable () -> Unit = {
        if (session.isBusy) Act(Icons.Filled.Stop, "停止", palette.error, enabled = session.status != "stopping", onClick = onStop)
        if (replying) Act(Icons.Filled.Bolt, "插队", palette.selection, palette.accent, ready) { onSend(true) }
        if (!session.isBusy || replying) Act(Icons.Filled.ArrowUpward, if (replying) "排队" else "发送", MaterialTheme.colorScheme.primary, enabled = ready) { onSend(false) }
    }
    val field: @Composable (Modifier) -> Unit = { modifier ->
        BasicTextField(
            draft, onDraft,
            // Before the on-screen keyboard takes Esc to close itself.
            modifier.onPreInterceptKeyBeforeSoftKeyboard { event ->
                (event.type == KeyEventType.KeyDown && event.key == Key.Escape && session.isBusy).also { if (it) onStop() }
            }.onPreviewKeyEvent { event ->
                // Hardware keyboards only; on-screen keyboards insert the newline themselves.
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when {
                    event.key == Key.Escape && session.isBusy -> { onStop(); true }
                    event.key == Key.Enter && !event.isShiftPressed && ready -> { onSend(replying && (event.isCtrlPressed || event.isMetaPressed)); true }
                    else -> false
                }
            },
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = palette.text),
            cursorBrush = SolidColor(palette.accent),
            maxLines = if (compact) 2 else 6,
            decorationBox = { inner ->
                Box(Modifier.padding(horizontal = 6.dp, vertical = 6.dp)) {
                    if (draft.isEmpty()) Text(if (replying) "排队或插队" else "发消息", style = MaterialTheme.typography.bodyLarge, color = palette.dim, maxLines = 1)
                    inner()
                }
            },
        )
    }
    Surface(
        Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = if (compact) 4.dp else 8.dp),
        shape = MaterialTheme.shapes.large, color = palette.card, border = BorderStroke(1.dp, palette.line),
    ) {
        // The field keeps its place in both layouts, so it keeps the keyboard when one turns into the other.
        Column(Modifier.padding(start = 8.dp, end = 6.dp, top = if (compact) 2.dp else 6.dp, bottom = if (compact) 2.dp else 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                field(Modifier.weight(1f))
                if (compact) {
                    if (wide) Meter(session)
                    actions()
                }
            }
            if (!compact) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                ModeChip(session, model)
                Box(Modifier.weight(1f)) { ModelChip(session, model) }
                Meter(session, label = !narrow)
                Spacer(Modifier.width(4.dp))
                actions()
            }
        }
    }
}

@Composable
private fun Act(icon: ImageVector, label: String, fill: Color, tint: Color = MaterialTheme.colorScheme.onPrimary, enabled: Boolean = true, onClick: () -> Unit) {
    FilledIconButton(
        onClick, Modifier.size(36.dp), enabled,
        colors = IconButtonDefaults.filledIconButtonColors(containerColor = fill, contentColor = tint, disabledContainerColor = palette.line, disabledContentColor = palette.dim),
    ) { Icon(icon, label, Modifier.size(20.dp)) }
}

/** How full Claude's context window is, as last reported by the server. */
@Composable
private fun Meter(session: ChatSession, label: Boolean = true) {
    val context = session.context ?: return
    val tint = if (context.fraction >= 0.9f) palette.error else if (context.fraction >= 0.75f) palette.warning else palette.muted
    val track = palette.line
    Row(
        Modifier.semantics(mergeDescendants = true) { contentDescription = "上下文 ${context.label}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Canvas(Modifier.size(12.dp)) {
            val stroke = Stroke(2.dp.toPx(), cap = StrokeCap.Round)
            drawArc(track, 0f, 360f, false, style = stroke)
            drawArc(tint, -90f, 360f * context.fraction, false, style = stroke)
        }
        if (label) Text(context.label, style = MaterialTheme.typography.labelMedium, color = tint, maxLines = 1)
    }
}

@Composable
private fun Chip(label: String, modifier: Modifier = Modifier, tint: Color = palette.muted, onClick: () -> Unit) {
    Row(
        modifier.clip(MaterialTheme.shapes.small).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 6.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        Icon(Icons.Filled.ExpandMore, null, Modifier.size(14.dp), tint = tint)
    }
}

@Composable
private fun ModeChip(session: ChatSession, model: AppModel) {
    var open by remember { mutableStateOf(false) }
    val mode = session.preferences.permissionMode
    Box {
        Chip(PermissionModes.firstOrNull { it.first == mode }?.second ?: mode.orEmpty(), tint = if (mode == "bypassPermissions") palette.warning else palette.muted) { open = true }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            for ((value, label) in PermissionModes) DropdownMenuItem(
                text = { Text(label) },
                trailingIcon = { if (value == mode) Icon(Icons.Filled.Check, null, Modifier.size(18.dp)) },
                enabled = session.remoteTask == null,
                onClick = { open = false; if (value != mode) model.configure(session.id, session.preferences.copy(permissionMode = value)) },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelChip(session: ChatSession, model: AppModel) {
    var open by remember { mutableStateOf(false) }
    val offered by model.models.collectAsStateWithLifecycle()
    val models = offered[session.hostId].orEmpty()
    val chosen = session.preferences.selectedModel
    val current = models.firstOrNull { it.value == chosen }
    val effort = session.preferences.effort
    val name = current?.displayName ?: (chosen ?: session.model)?.let(::modelName) ?: "模型"
    Chip(if (effort != null && Efforts[effort] != null) "$name · ${Efforts[effort]}" else name) { open = true }
    if (!open) return
    var attempt by remember { mutableIntStateOf(0) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(attempt) { failed = false; failed = !model.fetchModels(session.id) }
    val idle = session.remoteTask == null
    // Opened whole: half open, the last row would sit under the gesture bar.
    ModalBottomSheet(onDismissRequest = { open = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = palette.popup) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 16.dp)) {
            if (models.isEmpty()) Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                if (failed) TextButton(onClick = { attempt++ }) { Text("重试") } else CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
            }
            for (item in models) {
                val selected = item.value == chosen || (chosen == null && item.value == "default")
                Row(
                    Modifier.fillMaxWidth().selectable(selected, enabled = idle, role = Role.RadioButton) {
                        // An effort the new model does not accept goes back to the model's own default.
                        val keep = effort?.takeIf { it in item.supportedEffortLevels.orEmpty() }
                        model.configure(session.id, session.preferences.copy(selectedModel = item.value.takeIf { it != "default" }, effort = keep))
                    }.padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(item.displayName ?: item.value, style = MaterialTheme.typography.bodyLarge, color = if (idle) palette.text else palette.dim)
                        item.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.muted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                    }
                    if (selected) Icon(Icons.Filled.Check, null, Modifier.size(18.dp), tint = palette.accent)
                }
            }
            val levels = (current ?: models.firstOrNull { it.value == "default" }.takeIf { chosen == null })?.supportedEffortLevels.orEmpty()
            if (levels.isNotEmpty()) {
                HorizontalDivider(Modifier.padding(vertical = 8.dp), color = palette.line)
                Row(Modifier.padding(horizontal = 20.dp).horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("思考", style = MaterialTheme.typography.labelLarge, color = palette.muted)
                    for (level in listOf<String?>(null) + levels) FilterChip(
                        selected = effort == level, enabled = idle,
                        onClick = { model.configure(session.id, session.preferences.copy(effort = level)) },
                        label = { Text(if (level == null) "默认" else Efforts[level] ?: level) },
                    )
                }
            }
        }
    }
}
