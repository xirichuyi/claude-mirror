package claudemirror.app

import android.app.Application
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import claudemirror.app.ui.MirrorApp
import java.security.Security
import org.bouncycastle.jce.provider.BouncyCastleProvider

class MirrorApplication : Application() {
    lateinit var model: AppModel
        private set

    override fun onCreate() {
        super.onCreate()
        // Android ships a cut-down provider under the same name; SSH key exchange needs the full one.
        Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
        Security.insertProviderAt(BouncyCastleProvider(), 1)
        model = AppModel(this)
    }
}

class MainActivity : ComponentActivity() {
    private val model: AppModel get() = (application as MirrorApplication).model

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) intent.session()?.let { model.target.value = it }
        enableEdgeToEdge()
        setContent { MirrorApp(model) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.session()?.let { model.target.value = it }
    }

    override fun onStart() {
        super.onStart()
        model.resume()
    }

    override fun onStop() {
        model.pause()
        super.onStop()
    }
}
