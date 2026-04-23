package com.garmiand.protocol

import com.garmiand.domain.RoutePackage
import java.util.UUID

class JsonRouteChunkEncoder : RouteChunkEncoder {
    override fun encode(route: RoutePackage, chunkSizeBytes: Int): List<SyncMessage> {
        val sessionId = UUID.randomUUID().toString()
        val body = buildString {
            append("{\"routeId\":\"")
            append(route.routeId)
            append("\",\"name\":\"")
            append(route.name)
            append("\",\"points\":[")
            append(route.points.joinToString(",") { "{\"lat\":${it.lat},\"lon\":${it.lon}}" })
            append("],\"markers\":[")
            append(route.markers.joinToString(",") {
                "{\"id\":\"${it.id}\",\"lat\":${it.lat},\"lon\":${it.lon},\"title\":\"${it.title}\"}"
            })
            append("]}")
        }

        val chunks = body.chunked(chunkSizeBytes)
        val messages = mutableListOf<SyncMessage>(
            SyncMessage.SyncStart(sessionId, route.routeId, route.name),
        )

        chunks.forEachIndexed { index, value ->
            messages += SyncMessage.RouteChunk(
                sessionId = sessionId,
                chunkIndex = index,
                chunkCount = chunks.size,
                payloadUtf8 = value,
            )
        }

        messages += SyncMessage.SyncFinish(sessionId, route.routeId)
        return messages
    }
}
