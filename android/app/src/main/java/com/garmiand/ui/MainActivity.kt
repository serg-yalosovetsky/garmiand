package com.garmiand.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import com.garmiand.BuildConfig
import com.garmiand.R
import com.garmiand.domain.RoutePackage
import com.garmiand.garmin.ConnectIQGarminCompanion
import com.garmiand.map.QuantizedBundle
import com.garmiand.map.TileBundleSerializer
import com.garmiand.map.TileQuantizer
import com.garmiand.osmand.GpxFileImportBridge
import com.garmiand.protocol.NativeMapEncoder
import com.garmiand.protocol.SyncMessage
import com.garmiand.sync.BleChunkSizeProber
import com.garmiand.sync.MapBundleBleSender
import com.garmiand.sync.MapBundleUploadError
import com.garmiand.sync.MapBundleUploader
import com.garmiand.sync.RouteSyncOrchestrator
import com.garmiand.sync.SyncResult
import com.garmiand.util.AppLog
import java.util.UUID

private const val TAG = "MainActivity"
private const val REQUEST_GPX_FILE = 1001
private const val BBOX_PADDING_FRACTION = 0.15

class MainActivity : AppCompatActivity() {

    private lateinit var tvStatus: TextView
    private lateinit var btnImport: Button
    private lateinit var btnSend: Button
    private lateinit var progressBar: ProgressBar
    private lateinit var tvLog: TextView
    private lateinit var logScroll: ScrollView
    private lateinit var switchCacheMap: SwitchCompat
    private lateinit var switchOnlineMode: SwitchCompat
    private lateinit var btnProbeBle: Button

    private val gpxBridge = GpxFileImportBridge()
    private lateinit var garminCompanion: ConnectIQGarminCompanion
    private var loadedRoute: RoutePackage? = null

    private val logListener: (String) -> Unit = { line ->
        runOnUiThread {
            if (line == "__CLEAR__") {
                tvLog.text = ""
            } else {
                tvLog.append(line + "\n")
                logScroll.post { logScroll.fullScroll(View.FOCUS_DOWN) }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvStatus = findViewById(R.id.tv_status)
        btnImport = findViewById(R.id.btn_import)
        btnSend = findViewById(R.id.btn_send)
        progressBar = findViewById(R.id.progress_bar)
        tvLog = findViewById(R.id.tv_log)
        logScroll = findViewById(R.id.log_scroll)
        switchCacheMap = findViewById(R.id.switch_cache_map)
        switchOnlineMode = findViewById(R.id.switch_online_mode)
        btnProbeBle = findViewById(R.id.btn_probe_ble)

        switchCacheMap.setOnCheckedChangeListener { _, checked ->
            switchOnlineMode.isEnabled = checked
        }
        switchOnlineMode.isEnabled = switchCacheMap.isChecked

        btnSend.isEnabled = false

        btnImport.setOnClickListener { pickGpxFile() }
        btnSend.setOnClickListener { sendRoute() }
        btnProbeBle.setOnClickListener { probeBleChunkSize() }
        findViewById<Button>(R.id.btn_clear_log).setOnClickListener { AppLog.clear() }
        findViewById<Button>(R.id.btn_copy_log).setOnClickListener {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("garmiand-log", AppLog.snapshot()))
            Toast.makeText(this, "Log copied", Toast.LENGTH_SHORT).show()
        }

        AppLog.addListener(logListener)
        val tok = BuildConfig.BACKEND_TOKEN
        val tokFingerprint = if (tok.length >= 6) "${tok.take(3)}…${tok.takeLast(3)} (len=${tok.length})" else "(len=${tok.length})"
        AppLog.i(TAG, "App started backendUrl='${BuildConfig.BACKEND_URL}' token=$tokFingerprint")

        garminCompanion = ConnectIQGarminCompanion(this)
        tvStatus.text = "Connecting to Garmin..."
        AppLog.i(TAG, "Initializing Connect IQ...")
        garminCompanion.initialize { ready ->
            runOnUiThread {
                tvStatus.text = if (ready) "Garmin connected" else "Garmin not available"
            }
            AppLog.i(TAG, "Garmin ready=$ready")
        }
    }

    private fun pickGpxFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        startActivityForResult(intent, REQUEST_GPX_FILE)
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_GPX_FILE && resultCode == Activity.RESULT_OK) {
            val uri = data?.data ?: return
            val route = gpxBridge.loadFromUri(this, uri)
            if (route != null) {
                loadedRoute = route
                tvStatus.text = "Loaded: ${route.name} (${route.points.size} pts)"
                btnSend.isEnabled = true
                AppLog.i(TAG, "GPX loaded: ${route.name} pts=${route.points.size} markers=${route.markers.size}")
            } else {
                tvStatus.text = "Failed to parse GPX"
                AppLog.w(TAG, "Failed to parse GPX from $uri")
            }
        }
    }

    private fun sendRoute() {
        val route = loadedRoute ?: return
        val cacheMap = switchCacheMap.isChecked
        val onlineMode = switchOnlineMode.isChecked
        btnSend.isEnabled = false
        progressBar.visibility = View.VISIBLE
        progressBar.progress = 0
        AppLog.i(TAG, "sendRoute: pts=${route.points.size} cacheMap=$cacheMap onlineMode=$onlineMode")

        Thread {
            val orchestrator = RouteSyncOrchestrator(
                encoder = NativeMapEncoder(),
                companion = garminCompanion,
            )
            val result = orchestrator.sync(route) { sent, total ->
                runOnUiThread {
                    progressBar.progress = sent * 100 / total
                    tvStatus.text = "Sending $sent/$total..."
                }
            }
            AppLog.i(TAG, "sync result: $result")

            val mapStatus = if (cacheMap && result is SyncResult.Ok) sendMapBundle(route, onlineMode) else null

            runOnUiThread {
                progressBar.visibility = View.GONE
                btnSend.isEnabled = true
                tvStatus.text = when (result) {
                    is SyncResult.Ok -> {
                        val mapSuffix = when (mapStatus) {
                            MapSendStatus.HTTPS_OK -> " + map (HTTPS)"
                            MapSendStatus.BLE_OK -> " + map (BLE)"
                            MapSendStatus.FAILED -> " (map failed)"
                            null -> ""
                        }
                        "Sent OK (${result.ackCount} msgs)$mapSuffix"
                    }
                    is SyncResult.Failed -> "Failed: ${result.reason}"
                }
            }
        }.start()
    }

    private enum class MapSendStatus { HTTPS_OK, BLE_OK, FAILED }

    private fun sendMapBundle(route: RoutePackage, onlineMode: Boolean): MapSendStatus {
        if (route.points.isEmpty()) return MapSendStatus.FAILED

        val bbox = computeBbox(route, BBOX_PADDING_FRACTION)
        AppLog.i(TAG, "Quantizing tiles for bbox lat[${bbox.minLat},${bbox.maxLat}] lon[${bbox.minLon},${bbox.maxLon}]")
        val quantized = try {
            TileQuantizer.quantize(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon)
        } catch (e: Exception) {
            AppLog.e(TAG, "Quantize failed", e)
            return MapSendStatus.FAILED
        }
        if (quantized.tiles.isEmpty()) {
            AppLog.w(TAG, "Quantize produced 0 tiles")
            return MapSendStatus.FAILED
        }
        val blob = TileBundleSerializer.serialize(quantized)
        AppLog.i(TAG, "Bundle ready: ${quantized.tiles.size} tiles, ${blob.size}B mode=${if (onlineMode) "HTTPS" else "BLE"}")

        return if (onlineMode) {
            uploadAndAnnounce(blob)
        } else {
            sendBundleViaBle(blob)
        }
    }

    private fun uploadAndAnnounce(bundle: ByteArray): MapSendStatus {
        val url = BuildConfig.BACKEND_URL
        if (url.isBlank()) {
            AppLog.w(TAG, "BACKEND_URL not configured — falling back to BLE")
            return sendBundleViaBle(bundle)
        }
        return try {
            val uploader = MapBundleUploader(url, BuildConfig.BACKEND_TOKEN)
            val result = uploader.upload(bundle)
            val sessionId = UUID.randomUUID().toString()
            val ack = garminCompanion.send(
                SyncMessage.TileSession(
                    sessionId = sessionId,
                    bundleId = result.bundleId,
                    downloadUrl = result.downloadUrl,
                )
            )
            AppLog.i(TAG, "tile_session ack ok=${ack.ok} reason=${ack.reason}")
            if (ack.ok) MapSendStatus.HTTPS_OK else MapSendStatus.FAILED
        } catch (e: MapBundleUploadError) {
            AppLog.w(TAG, "HTTPS upload failed (${e.message}) — falling back to BLE")
            sendBundleViaBle(bundle)
        }
    }

    private fun sendBundleViaBle(bundle: ByteArray): MapSendStatus {
        val sender = MapBundleBleSender(garminCompanion)
        val bundleId = sender.send(bundle) { sent, total ->
            runOnUiThread {
                progressBar.progress = sent * 100 / total
                tvStatus.text = "BLE chunk $sent/$total"
            }
        }
        return if (bundleId != null) MapSendStatus.BLE_OK else MapSendStatus.FAILED
    }

    private data class Bbox(val minLat: Double, val maxLat: Double, val minLon: Double, val maxLon: Double)

    private fun computeBbox(route: RoutePackage, paddingFraction: Double): Bbox {
        var minLat = Double.POSITIVE_INFINITY
        var maxLat = Double.NEGATIVE_INFINITY
        var minLon = Double.POSITIVE_INFINITY
        var maxLon = Double.NEGATIVE_INFINITY
        for (p in route.points) {
            if (p.lat < minLat) minLat = p.lat
            if (p.lat > maxLat) maxLat = p.lat
            if (p.lon < minLon) minLon = p.lon
            if (p.lon > maxLon) maxLon = p.lon
        }
        val padLat = (maxLat - minLat).coerceAtLeast(0.001) * paddingFraction
        val padLon = (maxLon - minLon).coerceAtLeast(0.001) * paddingFraction
        return Bbox(minLat - padLat, maxLat + padLat, minLon - padLon, maxLon + padLon)
    }

    private fun probeBleChunkSize() {
        btnProbeBle.isEnabled = false
        btnSend.isEnabled = false
        progressBar.visibility = View.VISIBLE
        progressBar.progress = 0
        AppLog.i(TAG, "BLE chunk-size probe starting...")
        val sizes = BleChunkSizeProber.DEFAULT_SIZES_KB
        Thread {
            val prober = BleChunkSizeProber(garminCompanion)
            var done = 0
            val results = prober.probe { kb, ok, reason ->
                done++
                runOnUiThread {
                    progressBar.progress = done * 100 / sizes.size
                    tvStatus.text = "${kb}KB ${if (ok) "ok" else "FAIL"} ($done/${sizes.size})"
                }
            }
            val maxOk = results.entries.lastOrNull { it.value }?.key
            val firstFail = results.entries.firstOrNull { !it.value }?.key
            runOnUiThread {
                progressBar.visibility = View.GONE
                btnProbeBle.isEnabled = true
                btnSend.isEnabled = loadedRoute != null
                tvStatus.text = "BLE limit: maxOk=${maxOk?.toString() ?: "-"}KB firstFail=${firstFail?.toString() ?: "-"}KB"
            }
        }.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        AppLog.removeListener(logListener)
        garminCompanion.shutdown()
    }
}
