package com.garmiand.protocol

import com.garmiand.domain.Marker
import com.garmiand.domain.RoutePackage

sealed interface SyncMessage {
    val sessionId: String

    data class SyncStart(
        override val sessionId: String,
        val routeId: String,
        val routeName: String,
        val chunkCount: Int,
    ) : SyncMessage

    data class RouteChunk(
        override val sessionId: String,
        val chunkIndex: Int,
        val lats: List<Double>,
        val lons: List<Double>,
    ) : SyncMessage

    data class Markers(
        override val sessionId: String,
        val markers: List<Marker>,
    ) : SyncMessage

    data class SyncFinish(
        override val sessionId: String,
        val routeId: String,
        val pointCount: Int,
    ) : SyncMessage
}

data class SyncAck(
    val sessionId: String,
    val ok: Boolean,
    val reason: String? = null,
)

interface RouteChunkEncoder {
    fun encode(route: RoutePackage, pointsPerChunk: Int = 50): List<SyncMessage>
}
