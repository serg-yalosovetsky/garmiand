package com.garmiand.protocol

import com.garmiand.domain.Marker
import com.garmiand.domain.RoutePackage
import java.util.UUID

class NativeMapEncoder : RouteChunkEncoder {
    override fun encode(route: RoutePackage, pointsPerChunk: Int): List<SyncMessage> {
        val sessionId = UUID.randomUUID().toString()
        val chunks = route.points.chunked(pointsPerChunk)
        val messages = mutableListOf<SyncMessage>()

        messages += SyncMessage.SyncStart(
            sessionId = sessionId,
            routeId = route.routeId,
            routeName = route.name,
            chunkCount = chunks.size,
        )
        chunks.forEachIndexed { idx, pts ->
            messages += SyncMessage.RouteChunk(
                sessionId = sessionId,
                chunkIndex = idx,
                lats = pts.map { it.lat },
                lons = pts.map { it.lon },
            )
        }
        if (route.markers.isNotEmpty()) {
            messages += SyncMessage.Markers(
                sessionId = sessionId,
                markers = route.markers,
            )
        }
        messages += SyncMessage.SyncFinish(
            sessionId = sessionId,
            routeId = route.routeId,
            pointCount = route.points.size,
        )
        return messages
    }
}

object SyncMessageSerializer {
    fun toMap(msg: SyncMessage): Map<String, Any> = when (msg) {
        is SyncMessage.SyncStart -> mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_SYNC_START,
            PhoneMessageEnvelope.KEY_SESSION_ID to msg.sessionId,
            PhoneMessageEnvelope.KEY_ROUTE_ID to msg.routeId,
            PhoneMessageEnvelope.KEY_ROUTE_NAME to msg.routeName,
            PhoneMessageEnvelope.KEY_CHUNK_COUNT to msg.chunkCount,
        )
        is SyncMessage.RouteChunk -> mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_ROUTE_CHUNK,
            PhoneMessageEnvelope.KEY_SESSION_ID to msg.sessionId,
            PhoneMessageEnvelope.KEY_CHUNK_IDX to msg.chunkIndex,
            PhoneMessageEnvelope.KEY_LATS to msg.lats,
            PhoneMessageEnvelope.KEY_LONS to msg.lons,
        )
        is SyncMessage.Markers -> mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_MARKERS,
            PhoneMessageEnvelope.KEY_SESSION_ID to msg.sessionId,
            PhoneMessageEnvelope.KEY_MARKERS to msg.markers.map { m -> markerToMap(m) },
        )
        is SyncMessage.SyncFinish -> mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_SYNC_FINISH,
            PhoneMessageEnvelope.KEY_SESSION_ID to msg.sessionId,
            PhoneMessageEnvelope.KEY_ROUTE_ID to msg.routeId,
            PhoneMessageEnvelope.KEY_POINT_COUNT to msg.pointCount,
        )
        is SyncMessage.TileSession -> mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_TILE_SESSION,
            PhoneMessageEnvelope.KEY_SESSION_ID to msg.sessionId,
            PhoneMessageEnvelope.KEY_BUNDLE_ID to msg.bundleId,
            PhoneMessageEnvelope.KEY_DOWNLOAD_URL to msg.downloadUrl,
            PhoneMessageEnvelope.KEY_TOTAL_BYTES to msg.totalBytes,
        )
        is SyncMessage.TileChunk -> mapOf(
            PhoneMessageEnvelope.KEY_VERSION to PhoneMessageEnvelope.VERSION,
            PhoneMessageEnvelope.KEY_KIND to PhoneMessageEnvelope.KIND_TILE_CHUNK,
            PhoneMessageEnvelope.KEY_SESSION_ID to msg.sessionId,
            PhoneMessageEnvelope.KEY_BUNDLE_ID to msg.bundleId,
            PhoneMessageEnvelope.KEY_CHUNK_INDEX to msg.index,
            PhoneMessageEnvelope.KEY_CHUNK_TOTAL to msg.total,
            PhoneMessageEnvelope.KEY_CHUNK_TOTAL_BYTES to msg.totalBytes,
            PhoneMessageEnvelope.KEY_CHUNK_PAYLOAD to msg.payload,
        )
    }

    private fun markerToMap(m: Marker): Map<String, Any> = mapOf(
        PhoneMessageEnvelope.KEY_MARKER_ID to m.id,
        PhoneMessageEnvelope.KEY_MARKER_LAT to m.lat,
        PhoneMessageEnvelope.KEY_MARKER_LON to m.lon,
        PhoneMessageEnvelope.KEY_MARKER_TITLE to m.title,
    )
}
