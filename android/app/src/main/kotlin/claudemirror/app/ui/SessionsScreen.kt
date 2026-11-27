package claudemirror.app.ui

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.ChatSession
import claudemirror.core.ConnectionState

/** The state of a conversation in a few words, or null when there is nothing to say. */
fun ChatSession.statusLabel(): String? = when (status) {
    "connecting" -> "正在连接…"
    "working" -> "Claude 正在回复…"
    "permission" -> "等待你的确认"
    "stopping" -> "正在停止…"
    "detached" -> "已断开"
    "error" -> "出错了"
    "stopped" -> "已停止"
    else -> null
}

/** The last part of a path, which is how a project is known. */
fun folderName(path: String): String = path.trimEnd('/').substringAfterLast('/').ifEmpty { path }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SessionsScreen(model: AppModel, hostId: String, snackbar: SnackbarHostState, onBack: () -> Unit, onOpen: (String) -> Unit, onHistory: () -> Unit, onFiles: (String) -> Unit) {
    val hosts by model.hosts.collectAsStateWithLifecycle()
    val host = hosts.firstOrNull { it.id == hostId }
    if (host == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val connections by model.connections.collectAsStateWithLifecycle()
    val state = connections[hostId]
    val all by model.sessions.collectAsStateWithLifecycle()
    val sessions = all.filter { it.hostId == hostId }.sortedByDescending { it.updatedAt }
    // The project talked in last comes first; one without conversations keeps its place at the end.
    val projects = (sessions.map { it.directory } + host.directory + host.projects).distinct()
    var deleting by remember { mutableStateOf<ChatSession?>(null) }
    var renaming by remember { mutableStateOf<ChatSession?>(null) }
    var menu by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    LaunchedEffect(hostId) {
        if (state !is ConnectionState.Connected && state !is ConnectionState.Connecting) model.connect(host)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(host.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        // Connected with Claude found is how it should be, and goes without saying.
                        if ((state as? ConnectionState.Connected)?.info?.claude == null) Text(
                            state.label(), style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = if (state is ConnectionState.Failed) palette.error else palette.muted,
                        )
                    }
                },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = {
                    val connected = state is ConnectionState.Connected
                    IconButton(onClick = onHistory, enabled = connected) { Icon(Icons.Filled.History, "服务器对话") }
                    IconButton(onClick = { picking = true }, enabled = connected) { Icon(Icons.Filled.CreateNewFolder, "添加项目") }
                    IconButton(onClick = { model.reconnect(host) }) { Icon(Icons.Filled.Refresh, "重新连接") }
                },
            )
        },
        snackbarHost = { Snackbar(snackbar) },
        floatingActionButton = {
            ExtendedFloatingActionButton(onClick = { onOpen(model.createSession(host, projects.first()).id) }, icon = { Icon(Icons.Filled.Add, null) }, text = { Text("新对话") },
                shape = CircleShape, containerColor = palette.accentFill, contentColor = Color.White)
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (state is ConnectionState.Failed) {
                Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text(state.error.message ?: "连接失败", color = MaterialTheme.colorScheme.onErrorContainer)
                        TextButton(onClick = { model.reconnect(host) }) { Text("重试", color = MaterialTheme.colorScheme.onErrorContainer) }
                    }
                }
            }
            (state as? ConnectionState.Connected)?.info?.persistenceWarning?.let { warning ->
                Surface(color = MaterialTheme.colorScheme.tertiaryContainer, modifier = Modifier.fillMaxWidth()) {
                    Text(warning, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onTertiaryContainer, style = MaterialTheme.typography.bodySmall)
                }
            }
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 88.dp)) {
                // Two projects in folders of one name are told apart by where they are.
                val twins = projects.groupingBy(::folderName).eachCount()
                for (project in projects) {
                    val inside = sessions.filter { it.directory == project }
                    item(key = "project:$project") {
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (twins[folderName(project)] == 1) folderName(project) else project, Modifier.weight(1f),
                                style = MaterialTheme.typography.labelLarge, color = palette.muted, maxLines = 1, overflow = TextOverflow.StartEllipsis,
                            )
                            // Only a project added by hand and left empty can go; the others come from what is in them.
                            if (inside.isEmpty() && project in host.projects) TextButton(onClick = { model.removeProject(host, project) }) { Text("移除", color = palette.muted) }
                            IconButton(onClick = { onFiles(project) }, enabled = state is ConnectionState.Connected) { Icon(Icons.Filled.FolderOpen, "文件", Modifier.size(20.dp), tint = palette.muted) }
                            IconButton(onClick = { onOpen(model.createSession(host, project).id) }) { Icon(Icons.Filled.Add, "在 ${folderName(project)} 里新建对话", Modifier.size(20.dp), tint = palette.muted) }
                        }
                    }
                    items(inside, key = { it.id }) { session ->
                        // A conversation is its name; a second line only when something about it needs attention.
                        val working = session.isBusy && session.status != "detached" && session.status != "permission"
                        val note = session.statusLabel().takeUnless { session.status == "working" }
                        Box {
                            Row(
                                Modifier.fillMaxWidth().combinedClickable(onClick = { onOpen(session.id) }, onLongClick = { menu = session.id })
                                    .heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(session.name, style = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    if (note != null) Text(note, style = MaterialTheme.typography.bodySmall, color = if (session.status == "permission") palette.accent else palette.muted, maxLines = 1)
                                }
                                if (working) Spark(Modifier.size(18.dp), turning = true)
                            }
                            DropdownMenu(menu == session.id, onDismissRequest = { menu = null }) {
                                DropdownMenuItem(text = { Text("重命名") }, onClick = { menu = null; renaming = session })
                                DropdownMenuItem(text = { Text("删除", color = MaterialTheme.colorScheme.error) }, onClick = { menu = null; deleting = session })
                            }
                        }
                    }
                }
            }
        }
    }

    if (picking) FolderPicker(model, host, onDismiss = { picking = false }) { model.addProject(host, it); picking = false }

    renaming?.let { session ->
        var name by remember(session.id) { mutableStateOf(session.name) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("重命名") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true) },
            confirmButton = { TextButton(onClick = { model.rename(session.id, name); renaming = null }, enabled = name.isNotBlank()) { Text("保存") } },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("取消") } },
        )
    }

    deleting?.let { session ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除对话") },
            text = { Text("仅从手机删除") },
            confirmButton = { TextButton(onClick = { model.removeSession(session.id); deleting = null }) { Text("删除", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        )
    }
}
