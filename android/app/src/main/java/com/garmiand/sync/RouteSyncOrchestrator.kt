package com.garmiand.sync

import com.garmiand.domain.RoutePackage
import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.RouteChunkEncoder

class RouteSyncOrchestrator(
    private val encoder: RouteChunkEncoder,
    private val companion: GarminCompanion,
) {
    fun sync(route: RoutePackage): SyncResult {
        val messages = encoder.encode(route)
        val acks = messages.map { companion.send(it) }
        val hasError = acks.any { !it.ok }
        return if (hasError) {
            SyncResult.Failed(acks.firstOrNull { !it.ok }?.reason ?: "Unknown error")
        } else {
            SyncResult.Ok(acks.size)
        }
    }
}

sealed interface SyncResult {
    data class Ok(val ackCount: Int) : SyncResult
    data class Failed(val reason: String) : SyncResult
}
