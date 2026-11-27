package claudemirror.app.ui

import android.Manifest
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import claudemirror.app.AppModel
import claudemirror.core.ConnectionState

@Composable
fun MirrorApp(model: AppModel) {
    MirrorTheme {
        val navigation = rememberNavController()
        val snackbar = remember { SnackbarHostState() }
        LaunchedEffect(model) { model.snackbar.collect { snackbar.showSnackbar(it) } }
        val trust by model.trust.collectAsStateWithLifecycle()

        // Asked once, when the first reply starts: that is when being told about it matters.
        val allow = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        val running by model.running.collectAsStateWithLifecycle()
        val context = LocalContext.current
        LaunchedEffect(running.isNotEmpty()) {
            val refused = Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            if (running.isNotEmpty() && refused && model.askNotifications()) allow.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        val target by model.target.collectAsStateWithLifecycle()
        LaunchedEffect(target) {
            val session = model.sessions.value.firstOrNull { it.id == target }
            model.target.value = null
            if (session == null) return@LaunchedEffect
            // The list of conversations, which otherwise connects, is passed over.
            val state = model.connections.value[session.hostId]
            if (state !is ConnectionState.Connected && state !is ConnectionState.Connecting) model.host(session.hostId)?.let(model::connect)
            navigation.navigate("host/${session.hostId}") { popUpTo("hosts") }
            navigation.navigate("chat/${session.id}")
        }

        NavHost(navigation, startDestination = "hosts") {
            composable("hosts") {
                HostsScreen(model, snackbar, onOpen = { navigation.navigate("host/$it") }, onEdit = { navigation.navigate("edit/$it") })
            }
            composable("edit/{id}") { entry ->
                HostEditScreen(model, entry.arguments?.getString("id").orEmpty(), onDone = { navigation.popBackStack() })
            }
            composable("host/{id}") { entry ->
                val id = entry.arguments?.getString("id").orEmpty()
                SessionsScreen(model, id, snackbar, onBack = { navigation.popBackStack() }, onOpen = { navigation.navigate("chat/$it") }, onHistory = { navigation.navigate("history/$id") },
                    onFiles = { navigation.navigate("files/$id/" + Uri.encode(it)) })
            }
            composable("history/{id}") { entry ->
                // The chat takes the list's place, so Back from it returns to the conversations.
                HistoryScreen(model, entry.arguments?.getString("id").orEmpty(), snackbar, onBack = { navigation.popBackStack() },
                    onOpen = { navigation.navigate("chat/$it") { popUpTo("history/{id}") { inclusive = true } } })
            }
            composable("files/{id}/{path}") { entry ->
                val id = entry.arguments?.getString("id").orEmpty()
                FilesScreen(model, id, entry.arguments?.getString("path").orEmpty(), onBack = { navigation.popBackStack() },
                    onGit = { navigation.navigate("git/$id/" + Uri.encode(it)) })
            }
            composable("git/{id}/{path}") { entry ->
                GitScreen(model, entry.arguments?.getString("id").orEmpty(), entry.arguments?.getString("path").orEmpty(), onBack = { navigation.popBackStack() })
            }
            composable("chat/{id}") { entry ->
                ChatScreen(model, entry.arguments?.getString("id").orEmpty(), snackbar, onBack = { navigation.popBackStack() })
            }
        }

        trust?.let { request ->
            AlertDialog(
                onDismissRequest = { model.trust.value = null },
                title = { Text("确认服务器密钥") },
                text = {
                    Text("${request.host.address}\n\n${request.fingerprint}\n\ncat /etc/ssh/ssh_host_*_key.pub | ssh-keygen -lf -", fontFamily = FontFamily.Default)
                },
                confirmButton = { TextButton(onClick = { model.acceptKey(request) }) { Text("指纹一致，连接") } },
                dismissButton = { TextButton(onClick = { model.trust.value = null }) { Text("取消") } },
            )
        }
    }
}

@Composable
fun Snackbar(state: SnackbarHostState) = SnackbarHost(state)
