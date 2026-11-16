package com.izhaanintellect.sotto

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The ringing screen and the "guest is waiting" notice while the app is in
 * the background. The system plays the ringtone (so silent mode and Do Not
 * Disturb apply), and shows the call full screen when the phone is locked.
 * What they say (names or not) is decided by the Dart app.
 */
object CallNotifications {
    const val EXTRA_ACTION = "sotto.action"
    const val EXTRA_CALL = "sotto.call"

    /**
     * The ring's token. MainActivity is exported, so any app can start it with
     * the two extras above. Only a notification of ours carries the token: it
     * is random, and kept in this app's private preferences. The extras are
     * honoured only with the latest token (see [trusts]).
     */
    const val EXTRA_TOKEN = "sotto.token"

    private const val TOKEN_PREFS = "call_notifications"
    private const val TOKEN_KEY = "ring_token"

    private const val CALLS = "calls"
    private const val GUESTS = "guests"
    private const val MESSAGES = "messages"
    private const val CALL_ID = 2
    private const val KNOCK_ID = 3
    private const val MESSAGE_ID = 5

    fun showIncoming(context: Context, title: String, body: String, video: Boolean) {
        val manager = channels(context)
        val caller = Person.Builder().setName(body).setImportant(true).build()
        val token = newToken(context)
        val notification = NotificationCompat.Builder(context, CALLS)
            .setSmallIcon(R.drawable.ic_stat_sotto)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(activity(context, 10, null, call = true, token = token))
            .setFullScreenIntent(activity(context, 11, null, call = true, token = token), true)
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    caller,
                    PendingIntent.getBroadcast(
                        context, 12,
                        Intent(context, ActionReceiver::class.java).putExtra(EXTRA_ACTION, "decline"),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                    activity(context, 13, "answer", call = true, token = token),
                ).setIsVideo(video),
            )
            .build()
        // Ring until answered, declined or stopped.
        notification.flags = notification.flags or Notification.FLAG_INSISTENT
        manager.notify(CALL_ID, notification)
    }

    fun cancelIncoming(context: Context) = manager(context).cancel(CALL_ID)

    fun showKnock(context: Context, title: String, body: String) {
        val manager = channels(context)
        manager.notify(
            KNOCK_ID,
            NotificationCompat.Builder(context, GUESTS)
                .setSmallIcon(R.drawable.ic_stat_sotto)
                .setContentTitle(title)
                .setContentText(body)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setAutoCancel(true)
                .setContentIntent(openApp(context))
                .build(),
        )
    }

    fun cancelKnock(context: Context) = manager(context).cancel(KNOCK_ID)

    /** A message from a contact. The text itself never reaches this side. */
    fun showMessage(context: Context, title: String, body: String) {
        val manager = channels(context)
        manager.notify(
            MESSAGE_ID,
            NotificationCompat.Builder(context, MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_sotto)
                .setContentTitle(title)
                .setContentText(body)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setAutoCancel(true)
                .setContentIntent(openApp(context))
                .build(),
        )
    }

    fun cancelMessage(context: Context) = manager(context).cancel(MESSAGE_ID)

    /** Opens the app. */
    fun openApp(context: Context): PendingIntent = activity(context, 14, null, call = false)

    private fun activity(
        context: Context,
        code: Int,
        action: String?,
        call: Boolean,
        token: String? = null,
    ): PendingIntent =
        PendingIntent.getActivity(
            context, code,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_CALL, call)
                .apply {
                    if (token != null) putExtra(EXTRA_TOKEN, token)
                    if (action != null) putExtra(EXTRA_ACTION, action)
                },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * A new token for the ring being shown. It replaces the last one, so taps
     * on an older notification stop working. Saved before the notification
     * uses it, so a process that was restarted can still honour the tap.
     */
    private fun newToken(context: Context): String {
        val token = ByteArray(16).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
        tokens(context).edit().putString(TOKEN_KEY, token).commit()
        return token
    }

    /** Whether [token] is the one the latest ring carries. */
    fun trusts(context: Context, token: String?): Boolean {
        if (token == null) return false
        val expected = tokens(context).getString(TOKEN_KEY, null) ?: return false
        return MessageDigest.isEqual(expected.toByteArray(), token.toByteArray())
    }

    private fun tokens(context: Context) =
        context.getSharedPreferences(TOKEN_PREFS, Context.MODE_PRIVATE)

    private fun manager(context: Context) =
        context.getSystemService(NotificationManager::class.java)

    private fun channels(context: Context): NotificationManager {
        val manager = manager(context)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CALLS, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Rings for calls while Sotto is in the background"
                    setSound(
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 800, 600, 800)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(GUESTS, "Waiting guests", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "A guest knocked on your link while Sotto is in the background"
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(MESSAGES, "Messages", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "A message from a contact arrived while Sotto is in the background"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
            )
        }
        return manager
    }
}
