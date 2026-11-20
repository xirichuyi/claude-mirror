package claudemirror.app

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import claudemirror.app.ui.MirrorApp
import java.security.Security
import org.bouncycastle.jce.provider.BouncyCastleProvider

class MirrorApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Android ships a cut-down provider under the same name; SSH key exchange needs the full one.
        Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
        Security.insertProviderAt(BouncyCastleProvider(), 1)
    }
}

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { MirrorApp(model) }
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
