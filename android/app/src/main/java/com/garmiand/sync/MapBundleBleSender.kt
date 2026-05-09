package com.garmiand.sync

import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.SyncMessage
import com.garmiand.util.AppLog
import java.util.UUID

private const val TAG = "MapBundleBleSender"
// Empirically Garmin BLE moves ~370 B/s on Fenix 7 — a 3 KB chunk took
// ~8.2 s to ack, just past our previous 8 s busy-wait deadline. Smaller
// chunks ack faster *per* chunk, so failures (and progress UI) are tighter
// even though total throughput is roughly the same.
private const val DEFAULT_CHUNK_SIZE = 1500
private const val INTER_CHUNK_DELAY_MS = 150L
private const val MAX_RETRIES = 2
private const val RETRY_BACKOFF_MS = 1500L

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
            val msg = SyncMessage.TileChunk(
                sessionId = sessionId,
                bundleId = bundleId,
                index = i,
                total = total,
                payload = payload,
            )
            var attempt = 0
            var ok = false
            while (attempt <= MAX_RETRIES && !ok) {
                val ack = companion.send(msg)
                if (ack.ok) {
                    ok = true
                } else {
                    AppLog.w(TAG, "chunk $i/$total attempt ${attempt + 1} failed: ${ack.reason}")
                    attempt++
                    if (attempt <= MAX_RETRIES) {
                        Thread.sleep(RETRY_BACKOFF_MS)
                    }
                }
            }
            onProgress?.invoke(i + 1, total)
            if (!ok) {
                AppLog.w(TAG, "chunk $i/$total exhausted retries — aborting")
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
