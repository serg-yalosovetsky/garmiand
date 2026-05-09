package com.garmiand.sync

import com.garmiand.garmin.GarminCompanion
import com.garmiand.protocol.SyncAck
import com.garmiand.protocol.SyncMessage
import com.garmiand.util.AppLog
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

private const val TAG = "BleChunkSizeProber"

/**
 * Sends a series of single-chunk `tile_chunk` messages of increasing size to
 * probe the per-message BLE payload limit on the currently connected watch.
 *
 * Each probe is a self-contained valid GMND bundle (header + 64-color
 * palette + zero filler), shipped as `TileChunk(index=0, total=1)`, so the
 * watch's BleChunkAssembler persists it immediately and the on-screen
 * `[TILES] xxx ok/∅` badge reflects the latest accepted size.
 *
 * The 2 s inter-probe delay leaves the Connect IQ outbound queue empty
 * between sends — `MapBundleBleSender`'s 150 ms is fine for steady-state
 * but here we want unambiguous one-at-a-time failure attribution.
 */
class BleChunkSizeProber(
    private val companion: GarminCompanion,
    private val sizesKb: List<Int> = DEFAULT_SIZES_KB,
    private val delayMs: Long = 2000L,
) {

    fun probe(onResult: ((kb: Int, ok: Boolean, reason: String?) -> Unit)? = null): Map<Int, Boolean> {
        val results = LinkedHashMap<Int, Boolean>()
        AppLog.i(TAG, "probe start: sizes=${sizesKb.joinToString(",")}KB delay=${delayMs}ms")
        for ((idx, kb) in sizesKb.withIndex()) {
            val payload = buildGmndBundle(kb * 1024)
            val sessionId = UUID.randomUUID().toString()
            val bundleId = "probe-${kb.toString().padStart(2, '0')}kb-${sessionId.take(8)}"
            val msg = SyncMessage.TileChunk(
                sessionId = sessionId,
                bundleId = bundleId,
                index = 0,
                total = 1,
                payload = payload,
            )
            AppLog.i(TAG, "probe ${kb}KB → payload=${payload.size}B bundleId=$bundleId")
            val ack: SyncAck = try {
                companion.send(msg)
            } catch (e: Exception) {
                AppLog.w(TAG, "send threw: ${e.message}")
                SyncAck(sessionId, false, e.message)
            }
            AppLog.i(TAG, "probe ${kb}KB result ok=${ack.ok} reason=${ack.reason}")
            results[kb] = ack.ok
            onResult?.invoke(kb, ack.ok, ack.reason)
            if (idx < sizesKb.size - 1) {
                Thread.sleep(delayMs)
            }
        }
        AppLog.i(
            TAG,
            "probe done: ${results.entries.joinToString(",") { "${it.key}KB=${if (it.value) "ok" else "fail"}" }}",
        )
        return results
    }

    /**
     * Build a GMND-valid bundle of [totalSize] bytes (min 216 — header +
     * 64-color palette). tileCount=0 so the watch decoder reads the header,
     * registers the bundle, and ignores the zero filler.
     */
    private fun buildGmndBundle(totalSize: Int): ByteArray {
        val size = maxOf(216, totalSize)
        val buf = ByteArray(size)
        val bb = ByteBuffer.wrap(buf).order(ByteOrder.BIG_ENDIAN)
        bb.put('G'.code.toByte())
        bb.put('M'.code.toByte())
        bb.put('N'.code.toByte())
        bb.put('D'.code.toByte())
        bb.put(1)              // version
        bb.put(64)             // paletteSize
        bb.putShort(0)         // tileCount
        bb.putFloat(50.45f)    // bbox minLat
        bb.putFloat(50.46f)    // bbox maxLat
        bb.putFloat(30.52f)    // bbox minLon
        bb.putFloat(30.54f)    // bbox maxLon
        for (i in 0 until 64) {
            val c = ((i * 4) and 0xff).toByte()
            buf[24 + i * 3] = c
            buf[24 + i * 3 + 1] = c
            buf[24 + i * 3 + 2] = c
        }
        return buf
    }

    companion object {
        // Small → large; doubling-then-halving cadence so a binary-search-style
        // observation works without manual reconfiguration. Stops at 32 KB which
        // is well past any documented per-message Connect IQ Mobile SDK limit.
        val DEFAULT_SIZES_KB: List<Int> = listOf(1, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 32)
    }
}
