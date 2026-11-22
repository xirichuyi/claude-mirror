package claudemirror.app.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.text.font.FontFamily
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import claudemirror.app.AppModel

@Composable
fun MirrorApp(model: AppModel) {
    MirrorTheme {
        val navigation = rememberNavController()
        val snackbar = remember { SnackbarHostState() }
        LaunchedEffect(model) { model.notices.collect { snackbar.showSnackbar(it) } }
        val trust by model.trust.collectAsStateWithLifecycle()

        NavHost(navigation, startDestination = "hosts") {
            composable("hosts") {
                HostsScreen(model, snackbar, onOpen = { navigation.navigate("host/$it") }, onEdit = { navigation.navigate("edit/$it") })
            }
            composable("edit/{id}") { entry ->
                HostEditScreen(model, entry.arguments?.getString("id").orEmpty(), onDone = { navigation.popBackStack() })
            }
            composable("host/{id}") { entry ->
                SessionsScreen(model, entry.arguments?.getString("id").orEmpty(), snackbar, onBack = { navigation.popBackStack() }, onOpen = { navigation.navigate("chat/$it") })
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
                    Text("第一次连接 ${request.host.address}。请核对它的密钥指纹，一致再继续：\n\n${request.fingerprint}\n\n在服务器上运行 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 可以看到同样的指纹。", fontFamily = FontFamily.Default)
                },
                confirmButton = { TextButton(onClick = { model.acceptKey(request) }) { Text("指纹一致，连接") } },
                dismissButton = { TextButton(onClick = { model.trust.value = null }) { Text("取消") } },
            )
        }
    }
}

@Composable
fun Snackbar(state: SnackbarHostState) = SnackbarHost(state)
