package com.garmiand.sync

import android.content.SharedPreferences
import com.garmiand.domain.RoutePoint
import com.garmiand.garmin.GarminCompanion
import com.garmiand.map.TileBundleSerializer
import com.garmiand.map.TileQuantizer
import com.garmiand.protocol.SyncMessage
import com.garmiand.util.AppLog
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sqrt

private const val TAG = "MapRequestResponder"

// Не пересобираем бандл, если часы стоят почти на месте: свежий бандл
// покрывает ~1 км вокруг центра, 300 м сдвига ничего не меняют.
private const val MIN_MOVE_METERS = 300.0

// Буфер коридора вокруг одиночной точки: ×4 от маршрутного (z13 → 1200 м).
private const val POINT_BUFFER_SCALE = 4.0

/**
 * Авто-докачка карты для часов: часы шлют `map_request {lat, lon}`, когда
 * пользователь приближается к краю закэшированного бандла; мы собираем свежий
 * мульти-зум бандл вокруг точки и отдаём его тем же путём, что и обычный
 * (HTTPS с fallback на BLE). Один запрос за раз, повторные молча отбрасываются.
 */
class MapRequestResponder(
    private val companion: GarminCompanion,
    private val backendUrl: String,
    private val backendToken: String,
    private val blePrefs: SharedPreferences,
    private val onStatus: (String) -> Unit = {},
    // Resolves the active tile source at fetch time (so a toggle in the phone UI
    // takes effect for background auto-fetch too). Defaults to Bing Hybrid.
    private val tileUrlProvider: () -> String = { com.garmiand.map.BING_HYBRID_URL },
) {
    private val busy = AtomicBoolean(false)
    @Volatile private var lastLat = Double.NaN
    @Volatile private var lastLon = Double.NaN

    /** Вызывать из постоянного слушателя watch→phone. Не-map_request игнорируется. */
    fun handle(msg: Map<*, *>) {
        if (msg["kind"] != "map_request") return
        val lat = (msg["lat"] as? Number)?.toDouble() ?: return
        val lon = (msg["lon"] as? Number)?.toDouble() ?: return
        if (!lastLat.isNaN() && distanceMeters(lastLat, lastLon, lat, lon) < MIN_MOVE_METERS) {
            AppLog.d(TAG, "map_request ignored: moved <${MIN_MOVE_METERS.toInt()}m")
            return
        }
        if (!busy.compareAndSet(false, true)) {
            AppLog.d(TAG, "map_request ignored: busy")
            return
        }
        AppLog.i(TAG, "map_request lat=$lat lon=$lon — building bundle")
        onStatus("Auto-map: building…")
        Thread {
            try {
                val bundle = TileQuantizer.quantizeMultiZoom(
                    points = listOf(RoutePoint(lat, lon)),
                    urlTemplate = tileUrlProvider(),
                    bufferScale = POINT_BUFFER_SCALE,
                )
                if (bundle.tiles.isEmpty()) {
                    AppLog.w(TAG, "map_request: 0 tiles quantized")
                    return@Thread
                }
                val blob = TileBundleSerializer.serialize(bundle)
                AppLog.i(TAG, "map_request bundle: ${bundle.tiles.size} tiles ${blob.size}B")
                val ok = sendHttpsOrBle(blob)
                if (ok) {
                    lastLat = lat
                    lastLon = lon
                }
                onStatus(if (ok) "Auto-map: sent" else "Auto-map: FAILED")
            } catch (e: Exception) {
                AppLog.e(TAG, "map_request failed", e)
                onStatus("Auto-map: ${e.message}")
            } finally {
                busy.set(false)
            }
        }.start()
    }

    private fun sendHttpsOrBle(blob: ByteArray): Boolean {
        if (backendUrl.isNotBlank()) {
            try {
                val uploader = MapBundleUploader(backendUrl, backendToken)
                val result = uploader.upload(blob)
                val crc = java.util.zip.CRC32().apply { update(blob) }
                val ack = companion.send(
                    SyncMessage.TileSession(
                        sessionId = UUID.randomUUID().toString(),
                        bundleId = "%08x".format(crc.value),
                        downloadUrl = result.downloadUrl,
                        totalBytes = result.size,
                    )
                )
                if (ack.ok) return true
                AppLog.w(TAG, "tile_session ack failed: ${ack.reason} — falling back to BLE")
            } catch (e: MapBundleUploadError) {
                AppLog.w(TAG, "HTTPS upload failed (${e.message}) — falling back to BLE")
            }
        }
        return MapBundleBleSender(companion, blePrefs).send(blob) != null
    }

    private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val dLat = (lat2 - lat1) * 111_000.0
        val dLon = (lon2 - lon1) * 111_000.0 * cos(lat1 * PI / 180.0)
        return sqrt(dLat * dLat + dLon * dLon)
    }
}
