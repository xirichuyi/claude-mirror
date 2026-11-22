package claudemirror.app

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import claudemirror.core.Alert
import claudemirror.core.ChatSession
import claudemirror.core.permissionHeadline
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private const val SESSION = "session"
private const val PERMISSION = "permission"
private const val ALLOW = "allow"
private const val RUNNING = "running"
private const val NEWS = "news"
private const val ONGOING = 1

/** The conversation a notification was about, when the activity was opened from one. */
fun Intent.session(): String? = getStringExtra(SESSION)

/** What the app says while it is not on screen. */
class Notices(private val context: Context) {
    private val manager = NotificationManagerCompat.from(context)
    /** Posted and not yet withdrawn, including what a process before this one left behind. */
    private val shown = manager.activeNotifications.mapTo(HashSet()) { it.id }.apply { remove(ONGOING) }

    init {
        context.getSystemService(NotificationManager::class.java).createNotificationChannels(listOf(
            NotificationChannel(RUNNING, "回复中", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
            NotificationChannel(NEWS, "完成与确认", NotificationManager.IMPORTANCE_HIGH),
        ))
    }

    private fun open(session: String?): PendingIntent = PendingIntent.getActivity(
        context, session.hashCode(),
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra(SESSION, session),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun answer(session: String, permission: String, allow: Boolean): PendingIntent = PendingIntent.getBroadcast(
        context, (permission + allow).hashCode(),
        Intent(context, Answer::class.java).putExtra(SESSION, session).putExtra(PERMISSION, permission).putExtra(ALLOW, allow),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun ongoing(running: List<ChatSession>): Notification = NotificationCompat.Builder(context, RUNNING)
        .setSmallIcon(R.drawable.ic_notice)
        .setContentTitle(running.joinToString("、") { it.name }.ifEmpty { context.getString(R.string.app_name) })
        .setContentText("回复中")
        .setContentIntent(open(running.singleOrNull()?.id))
        .setOngoing(true).setOnlyAlertOnce(true)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .build()

    fun update(running: List<ChatSession>) = post(ONGOING, ongoing(running))

    /** Nothing is followed any more: "回复中" is not left behind by a service that has gone. */
    fun rest() = manager.cancel(ONGOING)

    fun tell(alert: Alert) {
        val session = alert.session
        val builder = NotificationCompat.Builder(context, NEWS)
            .setSmallIcon(R.drawable.ic_notice).setContentTitle(session.name).setContentIntent(open(session.id)).setAutoCancel(true)
        when (alert) {
            is Alert.Finished -> builder.setContentText(alert.text.ifEmpty { "已完成" }).setStyle(NotificationCompat.BigTextStyle().bigText(alert.text.take(400).ifEmpty { "已完成" }))
            is Alert.Failed -> builder.setContentText(alert.reason.ifEmpty { "已中断" })
            is Alert.Asked -> {
                val request = alert.permission
                val input = request.input as? JsonObject
                val command = (input?.get("command") as? JsonPrimitive)?.takeIf { it.isString }?.content
                builder.setContentText(permissionHeadline(request.name, request.input)).setCategory(NotificationCompat.CATEGORY_REMINDER)
                if (command != null) builder.setStyle(NotificationCompat.BigTextStyle().bigText(command.take(400)))
                // A question, a form or a plan is answered in the app, where it can be read whole.
                val plain = request.kind != "elicitation" && request.name != "ExitPlanMode" && (input?.get("questions") as? JsonArray).isNullOrEmpty()
                if (plain) {
                    builder.addAction(0, "拒绝", answer(session.id, request.id, false))
                    // Allowing a command takes the person who can unlock the phone. Before Android 12
                    // a notification cannot ask for that, so there it is allowed in the app.
                    val allow = if (Build.VERSION.SDK_INT >= 31) answer(session.id, request.id, true) else open(session.id)
                    builder.addAction(NotificationCompat.Action.Builder(0, "允许", allow).setAuthenticationRequired(true).build())
                }
            }
        }
        post(id(alert), builder.build())
    }

    private fun id(alert: Alert) = (if (alert is Alert.Asked) alert.permission.id else alert.session.id).hashCode().let { if (it == ONGOING) 0 else it }

    private fun post(id: Int, notification: Notification) {
        // Without the user's permission nothing is shown; the reply itself is unaffected.
        if (!manager.areNotificationsEnabled()) return
        try { manager.notify(id, notification); if (id != ONGOING) shown += id } catch (_: SecurityException) {}
    }

    /** A request that was answered, here or elsewhere, no longer asks. */
    fun settle(sessions: List<ChatSession>) {
        if (shown.isEmpty()) return
        val asking = sessions.flatMapTo(HashSet()) { session -> session.permissions.map { it.id.hashCode() } + session.id.hashCode() }
        shown.filter { it !in asking }.forEach { manager.cancel(it); shown -= it }
    }

    fun clear() {
        shown.forEach(manager::cancel)
        shown.clear()
    }
}

/**
 * Keeps the process, and with it the connection, while a reply is running on the server. Without it
 * Android freezes the app in the background and nothing can be told until it is opened again.
 */
class KeepAlive : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val model = (application as MirrorApplication).model
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        try { ServiceCompat.startForeground(this, ONGOING, model.notices.ongoing(model.running.value), type) } catch (_: RuntimeException) {
            // Android refused, as it does for an app long out of sight; the reply continues on the server.
            stopSelf()
            return START_NOT_STICKY
        }
        model.kept(true)
        if (model.running.value.isEmpty()) stopSelf()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        (application as MirrorApplication).model.kept(false)
        super.onDestroy()
    }

    companion object {
        /** False when Android does not let the app start it now. */
        fun start(context: Context): Boolean =
            try { ContextCompat.startForegroundService(context, Intent(context, KeepAlive::class.java)); true } catch (_: RuntimeException) { false }

        fun stop(context: Context) { context.stopService(Intent(context, KeepAlive::class.java)) }
    }
}

/** 允许 or 拒绝, pressed on a notification. */
class Answer : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val model = (context.applicationContext as MirrorApplication).model
        val allow = intent.getBooleanExtra(ALLOW, false)
        val session = intent.getStringExtra(SESSION) ?: return
        val permission = intent.getStringExtra(PERMISSION) ?: return
        if (allow && context.getSystemService(KeyguardManager::class.java).isDeviceLocked) return
        // The process is kept until the answer has been sent.
        val pending = goAsync()
        model.answer(session, permission, buildJsonObject {
            put("allow", allow)
            if (allow) put("useSuggestedPermissions", false) else put("reason", "")
        }, pending::finish)
    }
}
