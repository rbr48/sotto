package com.izhaanintellect.sotto

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Runs during a call, so the microphone keeps working when the user leaves
 * the app (Android mutes it for background apps otherwise). Its "Ongoing
 * call" notification returns to the call or hangs up.
 */
class CallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Ongoing call"
        val name = intent?.getStringExtra(EXTRA_NAME) ?: "Sotto"
        val since = intent?.getLongExtra(EXTRA_SINCE, 0L) ?: 0L
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification(title, name, since),
                if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0,
            )
        } catch (e: Exception) {
            // Android refuses a microphone service started from the
            // background: the call goes on while the app stays in front.
            Log.w("Sotto", "Call service not started: $e")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(title: String, name: String, since: Long): android.app.Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Ongoing calls", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown during a call; returns to it or hangs up"
                    setShowBadge(false)
                },
            )
        }
        val hangUp = PendingIntent.getBroadcast(
            this, 20,
            Intent(this, ActionReceiver::class.java).putExtra(CallNotifications.EXTRA_ACTION, "hangUp"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_sotto)
            .setContentTitle(title)
            .setContentText(name)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(CallNotifications.openApp(this))
            .setStyle(
                NotificationCompat.CallStyle.forOngoingCall(
                    Person.Builder().setName(name).build(),
                    hangUp,
                ),
            )
        if (since > 0) builder.setUsesChronometer(true).setWhen(since).setShowWhen(true)
        return builder.build()
    }

    companion object {
        private const val CHANNEL = "ongoing"
        private const val NOTIFICATION_ID = 4
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_SINCE = "since"

        /** Starts or updates it (e.g. when the call connects). */
        fun start(context: Context, title: String, name: String, since: Long?) {
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, CallService::class.java)
                        .putExtra(EXTRA_TITLE, title)
                        .putExtra(EXTRA_NAME, name)
                        .putExtra(EXTRA_SINCE, since ?: 0L),
                )
            } catch (e: Exception) {
                Log.w("Sotto", "Call service not started: $e")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallService::class.java))
        }
    }
}
