package claudemirror.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.HostConfig
import claudemirror.core.RemoteConversation
import claudemirror.core.RemoteListing
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** What a screen that asks the server for something is showing. */
private sealed interface Loaded<out T> {
    data object Waiting : Loaded<Nothing>
    data class Failed(val reason: String) : Loaded<Nothing>
    data class Ready<T>(val value: T) : Loaded<T>
}

private suspend fun <T> load(ask: suspend () -> T): Loaded<T> =
    try { Loaded.Ready(ask()) } catch (error: CancellationException) { throw error } catch (error: Exception) { Loaded.Failed(if ("EACCES" in error.message.orEmpty()) "无权读取" else error.message ?: "加载失败") }

@Composable
private fun <T> Loading(state: Loaded<T>, modifier: Modifier, onRetry: () -> Unit, content: @Composable (T) -> Unit) {
    when (state) {
        is Loaded.Ready -> Box(modifier) { content(state.value) }
        Loaded.Waiting -> Box(modifier, contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp) }
        is Loaded.Failed -> Column(modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(state.reason, color = palette.error, style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = onRetry) { Text("重试") }
        }
    }
}

/** Walks the server's folders and hands back the one chosen. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPicker(model: AppModel, host: HostConfig, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    var path by rememberSaveable { mutableStateOf("~") }
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<Loaded<RemoteListing>>(Loaded.Waiting) }
    LaunchedEffect(path, attempt) { state = Loaded.Waiting; state = load { model.folders(host, path) } }
    val listing = (state as? Loaded.Ready)?.value

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(listing?.path ?: path, style = CodeStyle, maxLines = 1, overflow = TextOverflow.StartEllipsis) },
                    navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "关闭") } },
                    actions = {
                        IconButton(onClick = { listing?.let { path = it.parent } }, enabled = listing != null && listing.parent != listing.path) { Icon(Icons.Filled.ArrowUpward, "上一级") }
                    },
                )
            },
            bottomBar = {
                Button(onClick = { listing?.let { onPick(it.path) } }, enabled = listing != null, modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(16.dp)) { Text("选这里") }
            },
        ) { padding ->
            Loading(state, Modifier.fillMaxSize().padding(padding), onRetry = { attempt++ }) { shown ->
                LazyColumn(Modifier.fillMaxSize()) {
                    items(shown.entries, key = { it.path }) { entry ->
                        ListItem(
                            leadingContent = { Icon(Icons.Filled.Folder, null, tint = palette.muted) },
                            headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            modifier = Modifier.clickable { path = entry.path },
                        )
                    }
                }
            }
        }
    }
}

/** The conversations Claude Code already has on the server; opening one continues it here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(model: AppModel, hostId: String, snackbar: SnackbarHostState, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val hosts by model.hosts.collectAsStateWithLifecycle()
    val host = hosts.firstOrNull { it.id == hostId }
    if (host == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<Loaded<List<RemoteConversation>>>(Loaded.Waiting) }
    LaunchedEffect(attempt) { state = Loaded.Waiting; state = load { model.history(host) } }
    val sessions by model.sessions.collectAsStateWithLifecycle()
    val here = sessions.filter { it.hostId == hostId }.mapNotNull { it.remoteSessionId }.toSet()
    var opening by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val dates = remember { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("服务器对话") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
            )
        },
        snackbarHost = { Snackbar(snackbar) },
    ) { padding ->
        Loading(state, Modifier.fillMaxSize().padding(padding), onRetry = { attempt++ }) { found ->
            if (found.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("没有对话", color = palette.muted) }
            else LazyColumn(Modifier.fillMaxSize()) {
                items(found, key = { it.reference }) { item ->
                    ListItem(
                        headlineContent = { Text(claudemirror.core.historyTitle(item.name), maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (item.sessionId in here) palette.muted else palette.text) },
                        supportingContent = { Text(folderName(item.directory) + " · " + dates.format(Date(item.updatedAt.toLong())), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        trailingContent = { if (opening == item.reference) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) },
                        modifier = Modifier.clickable(enabled = opening == null) {
                            opening = item.reference
                            scope.launch {
                                try { onOpen(model.adopt(host, item).id) }
                                catch (error: CancellationException) { throw error }
                                catch (error: Exception) { model.notices.tryEmit(error.message ?: "打开失败") }
                                finally { opening = null }
                            }
                        },
                    )
                }
            }
        }
    }
}
