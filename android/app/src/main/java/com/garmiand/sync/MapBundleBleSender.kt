package com.garmiand.sync

import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.SyncMessage
import com.garmiand.util.AppLog
import java.util.UUID

private const val TAG = "MapBundleBleSender"
private const val DEFAULT_CHUNK_SIZE = 3000
private const val INTER_CHUNK_DELAY_MS = 150L

class MapBundleBleSender(
    private val companion: GarminCompanion,
    private val chunkSize: Int = DEFAULT_CHUNK_SIZE,
) {
    /**
     * Splits [bundle] into chunks ≤ [chunkSize] bytes and sends them sequentially
     * via [GarminCompanion.send] as `TileChunk` messages. Returns the bundleId on
     * success (so caller can update Settings + log), or null on first failure.
     *
     * Garmin's Connect IQ Mobile SDK throttles send queue to ~3 outstanding
     * requests; the [INTER_CHUNK_DELAY_MS] gap keeps us well below that.
     */
    fun send(bundle: ByteArray, onProgress: ((sent: Int, total: Int) -> Unit)? = null): String? {
        val bundleId = UUID.randomUUID().toString()
        val sessionId = UUID.randomUUID().toString()
        val total = (bundle.size + chunkSize - 1) / chunkSize
        AppLog.i(TAG, "BLE send bundleId=$bundleId chunks=$total bytes=${bundle.size}")

        for (i in 0 until total) {
            val start = i * chunkSize
            val end = minOf(start + chunkSize, bundle.size)
            val payload = bundle.copyOfRange(start, end)
            val ack = companion.send(
                SyncMessage.TileChunk(
                    sessionId = sessionId,
                    bundleId = bundleId,
                    index = i,
                    total = total,
                    payload = payload,
                )
            )
            onProgress?.invoke(i + 1, total)
            if (!ack.ok) {
                AppLog.w(TAG, "chunk $i/$total failed: ${ack.reason}")
                return null
            }
            if (i < total - 1) {
                Thread.sleep(INTER_CHUNK_DELAY_MS)
            }
        }
        AppLog.i(TAG, "BLE send complete bundleId=$bundleId")
        return bundleId
    }
}
