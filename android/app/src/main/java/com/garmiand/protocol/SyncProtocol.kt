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

    data class TileSession(
        override val sessionId: String,
        val bundleId: String,
        val downloadUrl: String,
        val totalBytes: Int,
    ) : SyncMessage

    /** Sent before BLE chunk transfer to let the watch report already-received chunks. */
    data class BleBundleStart(
        override val sessionId: String,
        val bundleId: String,
        val total: Int,
        val totalBytes: Int,
    ) : SyncMessage

    data class TileChunk(
        override val sessionId: String,
        val bundleId: String,
        val index: Int,
        val total: Int,
        val totalBytes: Int,
        val payload: ByteArray,
    ) : SyncMessage {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is TileChunk) return false
            return sessionId == other.sessionId
                && bundleId == other.bundleId
                && index == other.index
                && total == other.total
                && totalBytes == other.totalBytes
                && payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int {
            var h = sessionId.hashCode()
            h = 31 * h + bundleId.hashCode()
            h = 31 * h + index
            h = 31 * h + total
            h = 31 * h + totalBytes
            h = 31 * h + payload.contentHashCode()
            return h
        }
    }
}

data class SyncAck(
    val sessionId: String,
    val ok: Boolean,
    val reason: String? = null,
)

interface RouteChunkEncoder {
    fun encode(route: RoutePackage, pointsPerChunk: Int = 50): List<SyncMessage>
}
