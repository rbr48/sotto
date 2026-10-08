package com.izhaanintellect.sotto

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** "Decline" on the ringing notification: no need to open the app. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(CallNotifications.EXTRA_ACTION) ?: return
        CallNotifications.cancelIncoming(context)
        Bridge.send(action)
    }
}
