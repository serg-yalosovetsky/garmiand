package com.garmiand.protocol

import com.garmiand.domain.RoutePackage

sealed interface SyncMessage {
    val sessionId: String
    fun toEnvelope(): PhoneEnvelope

    data class SyncStart(
        override val sessionId: String,
        val routeId: String,
        val routeName: String,
    ) : SyncMessage {
        override fun toEnvelope(): PhoneEnvelope = mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_SYNC_START,
            PhoneMessageEnvelope.KEY_SESSION_ID to sessionId,
            PhoneMessageEnvelope.KEY_ROUTE_ID to routeId,
            PhoneMessageEnvelope.KEY_ROUTE_NAME to routeName,
        )
    }

    data class RouteChunk(
        override val sessionId: String,
        val routeId: String,
        val chunkIndex: Int,
        val chunkCount: Int,
        val payloadBase64: String,
    ) : SyncMessage {
        override fun toEnvelope(): PhoneEnvelope = mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_ROUTE_CHUNK,
            PhoneMessageEnvelope.KEY_SESSION_ID to sessionId,
            PhoneMessageEnvelope.KEY_ROUTE_ID to routeId,
            PhoneMessageEnvelope.KEY_CHUNK_INDEX to chunkIndex,
            PhoneMessageEnvelope.KEY_CHUNK_COUNT to chunkCount,
            PhoneMessageEnvelope.KEY_PAYLOAD_B64 to payloadBase64,
        )
    }

    data class SyncFinish(
        override val sessionId: String,
        val routeId: String,
    ) : SyncMessage {
        override fun toEnvelope(): PhoneEnvelope = mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_SYNC_FINISH,
            PhoneMessageEnvelope.KEY_SESSION_ID to sessionId,
            PhoneMessageEnvelope.KEY_ROUTE_ID to routeId,
        )
    }
}

data class SyncAck(
    val sessionId: String,
    val ok: Boolean,
    val reason: String? = null,
)

interface RouteChunkEncoder {
    fun encode(route: RoutePackage, chunkSizeBytes: Int = 2048): List<SyncMessage>
}
