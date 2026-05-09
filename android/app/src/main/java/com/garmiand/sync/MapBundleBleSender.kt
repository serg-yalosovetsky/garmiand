package com.garmiand.sync

import android.content.SharedPreferences
import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.SyncMessage
import com.garmiand.util.AppLog
import java.util.UUID

private const val TAG = "MapBundleBleSender"

// Empirically the Connect IQ Mobile SDK rejects single tile_chunk messages
// > ~14 KB raw with FAILURE_MESSAGE_TOO_LARGE in ~10 ms (see BleChunkSizeProber
// notes). 12 KB leaves a small safety margin. We adapt downward at runtime
// and persist the last-known-good size in SharedPreferences.
private const val DEFAULT_CHUNK_SIZE = 12 * 1024
private const val MIN_CHUNK_SIZE = 1024
private const val INTER_CHUNK_DELAY_MS = 150L
private const val MAX_RETRIES = 2
private const val RETRY_BACKOFF_MS = 1500L
private const val PREFS_KEY_CHUNK_SIZE = "ble_chunk_size"

class MapBundleBleSender(
    private val companion: GarminCompanion,
    private val prefs: SharedPreferences? = null,
    initialChunkSize: Int = DEFAULT_CHUNK_SIZE,
) {
    private val startingChunkSize: Int =
        prefs?.getInt(PREFS_KEY_CHUNK_SIZE, initialChunkSize) ?: initialChunkSize

    /**
     * Splits [bundle] into chunks ≤ chunkSize bytes and sends them sequentially.
     * Adaptive sizing: starts from cached/default chunk size; on FAILURE_MESSAGE_TOO_LARGE
     * halves the size and restarts the bundle from chunk 0 (watch's BleChunkAssembler
     * resets when `total` changes — see BleChunkAssembler.mc:54). On success, caches
     * the working size for future sends.
     *
     * Returns the bundleId on success, or null after exhausting all chunk sizes.
     */
    fun send(bundle: ByteArray, onProgress: ((sent: Int, total: Int) -> Unit)? = null): String? {
        val bundleId = UUID.randomUUID().toString()
        val sessionId = UUID.randomUUID().toString()
        var chunkSize = startingChunkSize
        AppLog.i(TAG, "BLE send bundleId=$bundleId bytes=${bundle.size} startChunk=${chunkSize}B")

        while (chunkSize >= MIN_CHUNK_SIZE) {
            val total = (bundle.size + chunkSize - 1) / chunkSize
            AppLog.i(TAG, "Attempt chunkSize=${chunkSize}B chunks=$total")
            val outcome = sendOnePass(bundle, bundleId, sessionId, chunkSize, total, onProgress)
            when (outcome) {
                SendOutcome.OK -> {
                    AppLog.i(TAG, "BLE send complete bundleId=$bundleId chunkSize=${chunkSize}B")
                    persistChunkSize(chunkSize)
                    return bundleId
                }
                SendOutcome.TOO_LARGE -> {
                    chunkSize /= 2
                    AppLog.w(TAG, "Chunk too large — halving to ${chunkSize}B and retrying")
                    Thread.sleep(500L)
                }
                SendOutcome.OTHER_FAIL -> {
                    AppLog.w(TAG, "Non-size failure — aborting")
                    return null
                }
            }
        }
        AppLog.e(TAG, "BLE send failed: even ${MIN_CHUNK_SIZE}B chunks rejected")
        return null
    }

    private enum class SendOutcome { OK, TOO_LARGE, OTHER_FAIL }

    private fun sendOnePass(
        bundle: ByteArray,
        bundleId: String,
        sessionId: String,
        chunkSize: Int,
        total: Int,
        onProgress: ((sent: Int, total: Int) -> Unit)?,
    ): SendOutcome {
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
                    val reason = ack.reason ?: ""
                    AppLog.w(TAG, "chunk $i/$total (${payload.size}B) attempt ${attempt + 1} failed: $reason")
                    if (isTooLarge(reason)) {
                        return SendOutcome.TOO_LARGE
                    }
                    attempt++
                    if (attempt <= MAX_RETRIES) {
                        Thread.sleep(RETRY_BACKOFF_MS)
                    }
                }
            }
            onProgress?.invoke(i + 1, total)
            if (!ok) {
                AppLog.w(TAG, "chunk $i/$total exhausted retries — aborting")
                return SendOutcome.OTHER_FAIL
            }
            if (i < total - 1) {
                Thread.sleep(INTER_CHUNK_DELAY_MS)
            }
        }
        return SendOutcome.OK
    }

    private fun isTooLarge(reason: String): Boolean {
        // Reasons surfaced by Connect IQ Mobile SDK: FAILURE_MESSAGE_TOO_LARGE
        // is the canonical one. Match loosely so locale/version drift doesn't
        // hide the signal.
        val r = reason.uppercase()
        return r.contains("TOO_LARGE") || r.contains("MESSAGE_TOO") || r.contains("PAYLOAD_TOO")
    }

    private fun persistChunkSize(size: Int) {
        prefs?.edit()?.putInt(PREFS_KEY_CHUNK_SIZE, size)?.apply()
    }
}
