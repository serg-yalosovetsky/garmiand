package com.garmiand.sync

import com.garmiand.domain.RoutePackage
import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.RouteChunkEncoder

class RouteSyncOrchestrator(
    private val encoder: RouteChunkEncoder,
    private val companion: GarminCompanion,
) {
    fun sync(
        route: RoutePackage,
        onProgress: ((sent: Int, total: Int) -> Unit)? = null,
    ): SyncResult {
        val messages = encoder.encode(route)
        val total = messages.size
        messages.forEachIndexed { idx, msg ->
            val ack = companion.send(msg)
            onProgress?.invoke(idx + 1, total)
            if (!ack.ok) {
                return SyncResult.Failed(ack.reason ?: "Error at message $idx")
            }
        }
        return SyncResult.Ok(total)
    }
}

sealed interface SyncResult {
    data class Ok(val ackCount: Int) : SyncResult
    data class Failed(val reason: String) : SyncResult
}
