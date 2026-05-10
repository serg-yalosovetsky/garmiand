package com.garmiand.garmin

import com.garmiand.protocol.SyncAck
import com.garmiand.protocol.SyncMessage

/**
 * Обертка над Connect IQ Mobile SDK.
 * Здесь должен быть реальный sendMessage и callbacks ack/error.
 */
interface GarminCompanion {
    fun send(message: SyncMessage): SyncAck

    /** Register a listener for messages sent from the watch to the phone. */
    fun setWatchMessageListener(listener: ((Map<*, *>) -> Unit)?)
}

class LoggingGarminCompanion : GarminCompanion {
    override fun send(message: SyncMessage): SyncAck {
        return SyncAck(sessionId = message.sessionId, ok = true)
    }

    override fun setWatchMessageListener(listener: ((Map<*, *>) -> Unit)?) {}
}
