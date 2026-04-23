package com.garmiand.protocol

import com.garmiand.domain.RoutePackage
import java.util.Base64
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
        }.toByteArray(Charsets.UTF_8)

        val chunks = body.toList().chunked(chunkSizeBytes)
        val messages = mutableListOf<SyncMessage>(
            SyncMessage.SyncStart(sessionId, route.routeId, route.name),
        )

        chunks.forEachIndexed { index, bytes ->
            val payloadB64 = Base64.getEncoder().encodeToString(bytes.toByteArray())
            messages += SyncMessage.RouteChunk(
                sessionId = sessionId,
                routeId = route.routeId,
                chunkIndex = index,
                chunkCount = chunks.size,
                payloadBase64 = payloadB64,
            )
        }

        messages += SyncMessage.SyncFinish(sessionId, route.routeId)
        return messages
    }
}
