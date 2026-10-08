package com.izhaanintellect.sotto

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The one Flutter engine of the app. It outlives the window: when
 * "Ring even when Sotto is closed" is on, [SottoService] keeps the process
 * (and so this engine, its relay connection and its call logic) running
 * after the window is closed, and the window attaches to it again when it
 * opens.
 */
object SottoEngine {
    private const val ID = "sotto"

    /** The running engine, started on first use (main thread only). */
    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        Bridge.attach(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }
}
