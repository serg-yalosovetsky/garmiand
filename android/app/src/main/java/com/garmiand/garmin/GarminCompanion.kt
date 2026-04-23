package com.garmiand.garmin

import com.garmiand.protocol.SyncAck
import com.garmiand.protocol.SyncMessage

/**
 * Обертка над Connect IQ Mobile SDK.
 * Здесь должен быть реальный sendMessage и callbacks ack/error.
 */
interface GarminCompanion {
    fun send(message: SyncMessage): SyncAck
}

class LoggingGarminCompanion : GarminCompanion {
    override fun send(message: SyncMessage): SyncAck {
        // TODO: заменить на Connect IQ SDK transport.
        return SyncAck(sessionId = message.sessionId, ok = true)
    }
}
