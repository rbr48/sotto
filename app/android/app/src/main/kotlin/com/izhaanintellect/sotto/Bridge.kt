package com.izhaanintellect.sotto

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The `sotto/android` channel between the Dart app and Android: the
 * background service, permissions, and the incoming-call and knock
 * notifications. Taps on those notifications come back to Dart as
 * `action` calls ("answer", "decline", "open").
 */
object Bridge {
    private const val CHANNEL = "sotto/android"
    private const val PREFS = "sotto"
    private const val RING_WHEN_CLOSED = "ring_when_closed"

    private var channel: MethodChannel? = null
    private lateinit var app: Context

    /** The visible window, if any (for permission requests). */
    var activity: Activity? = null

    fun attach(context: Context, engine: FlutterEngine) {
        app = context
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                try {
                    result.success(handle(call.method, call.arguments))
                } catch (e: Exception) {
                    result.error("failed", e.message, null)
                }
            }
        }
    }

    /** Tells the Dart app what the user tapped. */
    fun send(action: String) {
        channel?.invokeMethod("action", action)
    }

    /** Whether the service should run (also read at boot). */
    fun ringWhenClosed(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(RING_WHEN_CLOSED, false)

    private fun handle(method: String, arguments: Any?): Any? {
        val args = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        return when (method) {
            "setRingWhenClosed" -> {
                val on = args["on"] == true
                app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putBoolean(RING_WHEN_CLOSED, on).apply()
                if (on) SottoService.start(app) else SottoService.stop(app)
                null
            }
            "status" -> mapOf(
                "batteryUnrestricted" to batteryUnrestricted(),
                "notificationsAllowed" to notificationsAllowed(),
                "fullScreenAllowed" to fullScreenAllowed(),
            )
            "requestNotifications" -> {
                val window = activity
                if (Build.VERSION.SDK_INT >= 33 && window != null && !notificationsAllowed()) {
                    window.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                } else if (!notificationsAllowed()) {
                    open(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName))
                }
                null
            }
            "requestBatteryExemption" -> {
                if (!batteryUnrestricted()) {
                    // Allowed for an app that must keep a connection to ring:
                    // without it, Android cuts the network in deep sleep.
                    @Suppress("BatteryLife")
                    open(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${app.packageName}")))
                }
                null
            }
            "openFullScreenSettings" -> {
                if (Build.VERSION.SDK_INT >= 34) {
                    open(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                        Uri.parse("package:${app.packageName}")))
                }
                null
            }
            "showIncomingCall" -> {
                CallNotifications.showIncoming(app, args["title"] as String, args["body"] as String,
                    args["video"] == true)
                null
            }
            "cancelIncomingCall" -> { CallNotifications.cancelIncoming(app); null }
            "showKnock" -> {
                CallNotifications.showKnock(app, args["title"] as String, args["body"] as String)
                null
            }
            "cancelKnock" -> { CallNotifications.cancelKnock(app); null }
            "callFinished" -> {
                (activity as? MainActivity)?.leaveLockScreen()
                null
            }
            else -> throw IllegalArgumentException("unknown method $method")
        }
    }

    private fun open(intent: Intent) {
        val window = activity
        if (window != null) window.startActivity(intent)
        else app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun batteryUnrestricted(): Boolean =
        (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(app.packageName)

    private fun notificationsAllowed(): Boolean =
        (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED) &&
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .areNotificationsEnabled()

    private fun fullScreenAllowed(): Boolean =
        Build.VERSION.SDK_INT < 34 ||
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .canUseFullScreenIntent()
}
