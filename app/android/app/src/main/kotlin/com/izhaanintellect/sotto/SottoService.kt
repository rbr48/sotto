package com.izhaanintellect.sotto

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * "Ring even when Sotto is closed": a foreground service that keeps the app
 * process, and with it the Flutter engine and its relay connection, alive
 * after the window is closed, so calls and knocking guests still ring.
 * It shows a quiet, permanent notification, as Android requires.
 */
class SottoService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(),
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0,
        )
        // After a reboot or after Android stopped the process, this starts
        // the app (headless) so it connects to the relay again.
        SottoEngine.get(this)
        return START_STICKY
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Ready for calls", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Keeps Sotto connected so calls ring while the app is closed"
                    setShowBadge(false)
                },
            )
        }
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_sotto)
            .setContentTitle("Sotto is ready for calls")
            .setContentText("Calls and waiting guests ring even when the app is closed.")
            .setContentIntent(CallNotifications.openApp(this))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL = "background"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, SottoService::class.java))
            } catch (e: Exception) {
                // Android 12+ refuses to start it from the background; it
                // starts the next time the app is opened.
                Log.w("Sotto", "Background service not started: $e")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SottoService::class.java))
        }
    }
}
