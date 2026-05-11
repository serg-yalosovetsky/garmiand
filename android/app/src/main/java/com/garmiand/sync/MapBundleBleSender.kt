package com.garmiand.sync

import android.content.SharedPreferences
import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.PhoneMessageEnvelope
import com.garmiand.protocol.SyncMessage
import com.garmiand.util.AppLog
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "MapBundleBleSender"

// 3 KB chunks give reliable BLE delivery within the ConnectIQ SDK's internal
// ~30 s per-message budget. Larger chunks (12 KB) consistently hit the budget
// and require retries. We still adapt downward if TOO_LARGE is returned.
private const val DEFAULT_CHUNK_SIZE = 3 * 1024
private const val MIN_CHUNK_SIZE = 1024
private const val INTER_CHUNK_DELAY_MS = 300L
private const val MAX_RETRIES = 4
private const val RETRY_BACKOFF_MS = 2500L
private const val PREFS_KEY_CHUNK_SIZE = "ble_chunk_size"

// Safety timer: if a single sending pass takes longer than this, pause for
// SAFETY_PAUSE_MS to give the watch's onUpdate() loop time to process the
// queued chunks and clear the BLE inbox.
private const val MAX_CONTINUOUS_MS = 2 * 60 * 1000L  // 2 min
private const val SAFETY_PAUSE_MS = 10_000L            // 10 s

// How long to wait for the watch's ble_wip_report response before assuming
// no WIP and sending all chunks from index 0.
private const val WIP_QUERY_TIMEOUT_MS = 3_000L

class MapBundleBleSender(
    private val companion: GarminCompanion,
    private val prefs: SharedPreferences? = null,
    initialChunkSize: Int = DEFAULT_CHUNK_SIZE,
) {
    private val startingChunkSize: Int =
        minOf(prefs?.getInt(PREFS_KEY_CHUNK_SIZE, initialChunkSize) ?: initialChunkSize, initialChunkSize)

    /**
     * Splits [bundle] into chunks ≤ chunkSize bytes and sends them sequentially.
     *
     * Before sending, queries the watch for already-received chunk indices via
     * ble_bundle_start → ble_wip_report handshake. The watch responds within
     * WIP_QUERY_TIMEOUT_MS; on timeout all chunks are sent from index 0.
     *
     * Adaptive sizing: starts from cached/default chunk size; on FAILURE_MESSAGE_TOO_LARGE
     * halves the size and restarts the bundle from chunk 0 (watch's BleChunkAssembler
     * resets when `total` changes). On success, caches the working size.
     *
     * Safety timer: pauses SAFETY_PAUSE_MS every MAX_CONTINUOUS_MS of sending to
     * allow the watch VM to process queued chunks without watchdog pressure.
     *
     * Returns the bundleId on success, or null after exhausting all chunk sizes.
     */
    fun send(bundle: ByteArray, onProgress: ((sent: Int, total: Int) -> Unit)? = null): String? {
        val bundleId = bundleHashString(bundle)
        val sessionId = UUID.randomUUID().toString()
        var chunkSize = startingChunkSize
        AppLog.i(TAG, "BLE send bundleId=$bundleId bytes=${bundle.size} startChunk=${chunkSize}B")

        while (chunkSize >= MIN_CHUNK_SIZE) {
            val total = (bundle.size + chunkSize - 1) / chunkSize
            AppLog.i(TAG, "Attempt chunkSize=${chunkSize}B chunks=$total")

            // Query watch for already-received chunks before this pass.
            val receivedIndices = queryWipFromWatch(sessionId, bundleId, total, bundle.size)
            AppLog.i(TAG, "WIP query: watch has ${receivedIndices.size}/$total chunks")

            val outcome = sendOnePass(bundle, bundleId, sessionId, chunkSize, total, receivedIndices, onProgress)
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

    /**
     * Send ble_bundle_start and wait up to WIP_QUERY_TIMEOUT_MS for the watch's
     * ble_wip_report. Returns the set of already-received chunk indices (empty on
     * timeout or any error).
     */
    private fun queryWipFromWatch(
        sessionId: String,
        bundleId: String,
        total: Int,
        totalBytes: Int,
    ): Set<Int> {
        val latch = CountDownLatch(1)
        val receivedRef = AtomicReference<Set<Int>>(emptySet())

        companion.setWatchMessageListener { msg ->
            val kind = msg[PhoneMessageEnvelope.KEY_KIND] as? String ?: return@setWatchMessageListener
            val msgBundleId = msg[PhoneMessageEnvelope.KEY_BUNDLE_ID] as? String ?: return@setWatchMessageListener
            if (kind == PhoneMessageEnvelope.KIND_BLE_WIP_REPORT && msgBundleId == bundleId) {
                @Suppress("UNCHECKED_CAST")
                val indices = (msg[PhoneMessageEnvelope.KEY_RECEIVED_INDICES] as? List<*>)
                    ?.mapNotNull { (it as? Number)?.toInt() }
                    ?.toSet()
                    ?: emptySet()
                receivedRef.set(indices)
                latch.countDown()
            }
        }

        try {
            val startMsg = SyncMessage.BleBundleStart(
                sessionId = sessionId,
                bundleId = bundleId,
                total = total,
                totalBytes = totalBytes,
            )
            val ack = companion.send(startMsg)
            if (!ack.ok) {
                AppLog.w(TAG, "ble_bundle_start send failed: ${ack.reason}")
                return emptySet()
            }
            latch.await(WIP_QUERY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            AppLog.w(TAG, "WIP query error: ${e.message}")
        } finally {
            companion.setWatchMessageListener(null)
        }

        return receivedRef.get()
    }

    private enum class SendOutcome { OK, TOO_LARGE, OTHER_FAIL }

    private fun sendOnePass(
        bundle: ByteArray,
        bundleId: String,
        sessionId: String,
        chunkSize: Int,
        total: Int,
        receivedIndices: Set<Int>,
        onProgress: ((sent: Int, total: Int) -> Unit)?,
    ): SendOutcome {
        var sessionStart = System.currentTimeMillis()

        for (i in 0 until total) {
            // Skip chunks the watch already has from a previous (interrupted) pass.
            if (receivedIndices.contains(i)) {
                AppLog.d(TAG, "skip chunk $i/$total (already on watch)")
                onProgress?.invoke(i + 1, total)
                continue
            }

            val start = i * chunkSize
            val end = minOf(start + chunkSize, bundle.size)
            val payload = bundle.copyOfRange(start, end)
            val msg = SyncMessage.TileChunk(
                sessionId = sessionId,
                bundleId = bundleId,
                index = i,
                total = total,
                totalBytes = bundle.size,
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

                // Safety timer: pause every MAX_CONTINUOUS_MS so the watch's onUpdate()
                // loop has time to drain queued chunks without watchdog pressure.
                val elapsed = System.currentTimeMillis() - sessionStart
                if (elapsed >= MAX_CONTINUOUS_MS) {
                    AppLog.i(TAG, "Safety pause ${SAFETY_PAUSE_MS}ms after ${elapsed}ms continuous send")
                    Thread.sleep(SAFETY_PAUSE_MS)
                    sessionStart = System.currentTimeMillis()
                }
            }
        }
        return SendOutcome.OK
    }

    private fun bundleHashString(bundle: ByteArray): String {
        val crc = java.util.zip.CRC32()
        crc.update(bundle)
        return "%08x".format(crc.value)
    }

    private fun isTooLarge(reason: String): Boolean {
        val r = reason.uppercase()
        return r.contains("TOO_LARGE") || r.contains("MESSAGE_TOO") || r.contains("PAYLOAD_TOO")
    }

    private fun persistChunkSize(size: Int) {
        prefs?.edit()?.putInt(PREFS_KEY_CHUNK_SIZE, size)?.apply()
    }
}
