package com.garmiand.protocol

import com.garmiand.domain.RoutePackage

sealed interface SyncMessage {
    val sessionId: String

    data class SyncStart(
        override val sessionId: String,
        val routeId: String,
        val routeName: String,
    ) : SyncMessage

    data class RouteChunk(
        override val sessionId: String,
        val chunkIndex: Int,
        val chunkCount: Int,
        val payloadUtf8: String,
    ) : SyncMessage

    data class SyncFinish(
        override val sessionId: String,
        val routeId: String,
    ) : SyncMessage
}

data class SyncAck(
    val sessionId: String,
    val ok: Boolean,
    val reason: String? = null,
)

interface RouteChunkEncoder {
    fun encode(route: RoutePackage, chunkSizeBytes: Int = 2048): List<SyncMessage>
}
