package com.garmiand.garmin

import com.garmiand.protocol.PhoneEnvelope
import com.garmiand.protocol.SyncAck
import com.garmiand.protocol.SyncMessage

/**
 * Обертка над Connect IQ Mobile SDK.
 * Здесь должен быть реальный sendMessage(envelope) и callbacks ack/error.
 */
interface GarminCompanion {
    fun send(message: SyncMessage): SyncAck
}

class LoggingGarminCompanion : GarminCompanion {
    override fun send(message: SyncMessage): SyncAck {
        val envelope: PhoneEnvelope = message.toEnvelope()
        val sessionId = envelope["session_id"] as? String ?: "unknown"
        // TODO: заменить на Connect IQ SDK transport.
        return SyncAck(sessionId = sessionId, ok = true)
    }
}
