package com.izhaanintellect.sotto

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The window. It shows the app's one engine ([SottoEngine]) and leaves it
 * running when closed, so a call can still ring (see [SottoService]).
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = SottoEngine.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    /** A tap to deliver once the window is visible. */
    private var pendingAction: String? = null

    override fun onResume() {
        super.onResume()
        Bridge.activity = this
        // Answering opens the microphone, which Android allows only to a
        // visible app: deliver it now, not while the window is being created.
        pendingAction?.let {
            pendingAction = null
            Bridge.send(it)
        }
    }

    override fun onDestroy() {
        if (Bridge.activity === this) Bridge.activity = null
        super.onDestroy()
    }

    /** Opened from the ringing notification: show over the lock screen. */
    private fun handle(intent: Intent) {
        if (intent.getBooleanExtra(CallNotifications.EXTRA_CALL, false)) showOnLockScreen(true)
        intent.getStringExtra(CallNotifications.EXTRA_ACTION)?.let {
            intent.removeExtra(CallNotifications.EXTRA_ACTION)
            CallNotifications.cancelIncoming(this)
            pendingAction = it
        }
    }

    /** The call is over: the app no longer shows over the lock screen. */
    fun leaveLockScreen() = showOnLockScreen(false)

    private fun showOnLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }
}
