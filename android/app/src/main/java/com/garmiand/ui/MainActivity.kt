package com.garmiand.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
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
// Extra, который шлёт MapsCreator (GarminSender.kt) вместе с EXTRA_STREAM.
private const val EXTRA_GMND_URI = "gmnd_uri"

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
    private lateinit var btnSendMap: Button

    private val gpxBridge = GpxFileImportBridge()
    private lateinit var garminCompanion: ConnectIQGarminCompanion
    private var loadedRoute: RoutePackage? = null
    // GMND-бандл, принятый извне (MapsCreator / share sheet) — шлётся на часы as-is.
    private var externalBundle: ByteArray? = null

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
        btnSendMap = findViewById(R.id.btn_send_map)

        switchCacheMap.setOnCheckedChangeListener { _, checked ->
            switchOnlineMode.isEnabled = checked
        }
        switchOnlineMode.isEnabled = switchCacheMap.isChecked

        btnSend.isEnabled = false

        btnImport.setOnClickListener { pickGpxFile() }
        btnSend.setOnClickListener { sendRoute() }
        btnSendMap.setOnClickListener { sendExternalBundle() }
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

        tvStatus.setOnClickListener { retryGarminConnect() }

        garminCompanion = ConnectIQGarminCompanion(this)
        connectToGarmin()

        handleIncomingGmnd(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingGmnd(intent)
    }

    // ── Приём .gmnd от MapsCreator (явный intent или share sheet) ──────────────

    private fun handleIncomingGmnd(intent: Intent?) {
        if (intent == null) return
        @Suppress("DEPRECATION")
        val uri: Uri = (intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)
            ?: intent.getStringExtra(EXTRA_GMND_URI)?.let(Uri::parse)
            ?: intent.data
            ?: return
        AppLog.i(TAG, "Incoming GMND uri=$uri")
        Thread {
            val blob = try {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } catch (e: Exception) {
                AppLog.e(TAG, "GMND read failed", e)
                null
            }
            runOnUiThread {
                if (blob == null) {
                    tvStatus.text = "Map file: read failed"
                    return@runOnUiThread
                }
                val err = validateGmnd(blob)
                if (err != null) {
                    AppLog.w(TAG, "GMND invalid: $err (${blob.size}B)")
                    tvStatus.text = "Map file: invalid ($err)"
                    return@runOnUiThread
                }
                val tileCount = ((blob[6].toInt() and 0xFF) shl 8) or (blob[7].toInt() and 0xFF)
                externalBundle = blob
                btnSendMap.isEnabled = true
                tvStatus.text = "Map loaded: $tileCount tiles, ${blob.size / 1024} KB"
                AppLog.i(TAG, "GMND accepted: $tileCount tiles ${blob.size}B id=${bundleHashString(blob)}")
            }
        }.start()
    }

    /** null = валиден; иначе — краткая причина. Формат см. TileBundleSerializer. */
    private fun validateGmnd(b: ByteArray): String? {
        if (b.size < 24) return "too small"
        if (b[0] != 'G'.code.toByte() || b[1] != 'M'.code.toByte() ||
            b[2] != 'N'.code.toByte() || b[3] != 'D'.code.toByte()
        ) return "bad magic"
        val version = b[4].toInt() and 0xFF
        if (version != TileBundleSerializer.VERSION) return "version $version"
        val paletteSize = b[5].toInt() and 0xFF
        if (paletteSize != com.garmiand.map.Palette.SIZE) return "palette $paletteSize"
        val tileCount = ((b[6].toInt() and 0xFF) shl 8) or (b[7].toInt() and 0xFF)
        if (tileCount == 0) return "no tiles"
        return null
    }

    private fun sendExternalBundle() {
        val blob = externalBundle ?: return
        val onlineMode = switchOnlineMode.isChecked
        btnSendMap.isEnabled = false
        progressBar.visibility = View.VISIBLE
        progressBar.progress = 0
        AppLog.i(TAG, "sendExternalBundle: ${blob.size}B mode=${if (onlineMode) "HTTPS" else "BLE"}")
        Thread {
            val status = if (onlineMode) uploadAndAnnounce(blob) else sendBundleViaBle(blob)
            runOnUiThread {
                progressBar.visibility = View.GONE
                btnSendMap.isEnabled = true
                tvStatus.text = when (status) {
                    MapSendStatus.HTTPS_OK -> "Map sent (HTTPS)"
                    MapSendStatus.BLE_OK -> "Map sent (BLE)"
                    MapSendStatus.FAILED -> "Map send FAILED"
                }
            }
        }.start()
    }

    private fun connectToGarmin() {
        tvStatus.text = "Connecting to Garmin..."
        AppLog.i(TAG, "Initializing Connect IQ...")
        garminCompanion.initialize { ready ->
            runOnUiThread {
                tvStatus.text = if (ready) "Garmin connected" else "Garmin not available (tap to retry)"
            }
            AppLog.i(TAG, "Garmin ready=$ready")
        }
    }

    private fun retryGarminConnect() {
        val status = tvStatus.text.toString()
        if (status.startsWith("Connecting") || status.startsWith("Garmin not available")) {
            AppLog.i(TAG, "Retrying Garmin connection...")
            garminCompanion.shutdown()
            garminCompanion = ConnectIQGarminCompanion(this)
            connectToGarmin()
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

        AppLog.i(TAG, "Quantizing multi-zoom corridor for ${route.points.size} pts (z12/z13/z15)")
        val quantized = try {
            TileQuantizer.quantizeMultiZoom(route.points)
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
        // Content-based ID — stable across sessions for the same route/tiles.
        // The watch keys its Storage on this; using a hash lets it skip re-download
        // when the tiles haven't changed (same route re-synced).
        val contentBundleId = bundleHashString(bundle)
        return try {
            val uploader = MapBundleUploader(url, BuildConfig.BACKEND_TOKEN)
            val result = uploader.upload(bundle)
            val sessionId = UUID.randomUUID().toString()
            val ack = garminCompanion.send(
                SyncMessage.TileSession(
                    sessionId = sessionId,
                    bundleId = contentBundleId,
                    downloadUrl = result.downloadUrl,
                    totalBytes = result.size,
                )
            )
            AppLog.i(TAG, "tile_session bundleId=$contentBundleId ack ok=${ack.ok} reason=${ack.reason}")
            if (ack.ok) MapSendStatus.HTTPS_OK else MapSendStatus.FAILED
        } catch (e: MapBundleUploadError) {
            AppLog.w(TAG, "HTTPS upload failed (${e.message}) — falling back to BLE")
            sendBundleViaBle(bundle)
        }
    }

    private fun bundleHashString(bundle: ByteArray): String {
        val crc = java.util.zip.CRC32()
        crc.update(bundle)
        return "%08x".format(crc.value)
    }

    private fun sendBundleViaBle(bundle: ByteArray): MapSendStatus {
        val prefs = getSharedPreferences("garmiand_ble", Context.MODE_PRIVATE)
        val sender = MapBundleBleSender(garminCompanion, prefs)
        val bundleId = sender.send(bundle) { sent, total ->
            runOnUiThread {
                progressBar.progress = sent * 100 / total
                tvStatus.text = "BLE chunk $sent/$total"
            }
        }
        return if (bundleId != null) MapSendStatus.BLE_OK else MapSendStatus.FAILED
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
