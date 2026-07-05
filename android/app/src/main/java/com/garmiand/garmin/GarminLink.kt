package com.garmiand.garmin

import android.content.Context
import com.garmiand.BuildConfig
import com.garmiand.sync.MapRequestResponder
import com.garmiand.util.AppLog
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "GarminLink"

/**
 * Единственная связь приложения с часами. Живёт вне Activity, чтобы
 * авто-докачка (map_request) работала при выключенном экране —
 * GarminLinkService держит процесс живым, а Activity лишь переиспользует
 * этот же companion.
 */
object GarminLink {

    enum class State { IDLE, CONNECTING, READY, FAILED }

    @Volatile
    var state: State = State.IDLE
        private set

    @Volatile
    private var companionInternal: ConnectIQGarminCompanion? = null

    private val pendingCallbacks = CopyOnWriteArrayList<(Boolean) -> Unit>()
    private val responderRegistered = AtomicBoolean(false)

    /** Companion создаётся лениво на applicationContext и переживает Activity. */
    @Synchronized
    fun obtain(context: Context): ConnectIQGarminCompanion {
        companionInternal?.let { return it }
        val c = ConnectIQGarminCompanion(context.applicationContext)
        companionInternal = c
        return c
    }

    /**
     * Инициализация Connect IQ + регистрация обработчика map_request (один раз).
     * Повторные вызовы во время CONNECTING просто дожидаются результата;
     * в READY — отвечают сразу.
     */
    @Synchronized
    fun ensureConnected(context: Context, onReady: ((Boolean) -> Unit)? = null) {
        when (state) {
            State.READY -> { onReady?.invoke(true); return }
            State.CONNECTING -> { onReady?.let { pendingCallbacks.add(it) }; return }
            else -> {}
        }
        state = State.CONNECTING
        onReady?.let { pendingCallbacks.add(it) }
        val appCtx = context.applicationContext
        val companion = obtain(appCtx)
        registerResponder(appCtx, companion)
        AppLog.i(TAG, "Initializing Connect IQ (state=$state)")
        companion.initialize { ready ->
            state = if (ready) State.READY else State.FAILED
            AppLog.i(TAG, "Connect IQ ready=$ready")
            val cbs = pendingCallbacks.toList()
            pendingCallbacks.clear()
            cbs.forEach { it(ready) }
        }
    }

    /** Полный сброс для ретрая (кнопка в статусе MainActivity). */
    @Synchronized
    fun reset() {
        companionInternal?.shutdown()
        companionInternal = null
        responderRegistered.set(false)
        state = State.IDLE
    }

    /** Ask the watch to stream its accumulated log buffer back (→ Loki). */
    fun requestWatchLogs(context: Context) {
        obtain(context.applicationContext).sendRaw(mapOf("kind" to "get_logs", "v" to 1))
    }

    private fun registerResponder(context: Context, companion: ConnectIQGarminCompanion) {
        if (!responderRegistered.compareAndSet(false, true)) return
        val responder = MapRequestResponder(
            companion = companion,
            backendUrl = BuildConfig.BACKEND_URL,
            backendToken = BuildConfig.BACKEND_TOKEN,
            blePrefs = context.getSharedPreferences("garmiand_ble", Context.MODE_PRIVATE),
            onStatus = { s -> AppLog.i(TAG, s) },
        )
        companion.addPersistentWatchListener { msg -> responder.handle(msg) }
        AppLog.i(TAG, "MapRequestResponder registered")
    }
}
