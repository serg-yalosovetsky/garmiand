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
import com.garmiand.R
import com.garmiand.domain.RoutePackage
import com.garmiand.garmin.ConnectIQGarminCompanion
import com.garmiand.map.MapTileServer
import com.garmiand.map.NetworkUtil
import com.garmiand.map.TileComposer
import com.garmiand.osmand.GpxFileImportBridge
import com.garmiand.protocol.NativeMapEncoder
import com.garmiand.protocol.SyncMessage
import com.garmiand.sync.RouteSyncOrchestrator
import com.garmiand.sync.SyncResult
import com.garmiand.util.AppLog
import java.util.UUID

private const val TAG = "MainActivity"
private const val REQUEST_GPX_FILE = 1001
private const val MAP_SERVER_PORT = 8081
private const val MAP_WIDTH = 240
private const val MAP_HEIGHT = 240
private const val BBOX_PADDING_FRACTION = 0.15

class MainActivity : AppCompatActivity() {

    private lateinit var tvStatus: TextView
    private lateinit var btnImport: Button
    private lateinit var btnSend: Button
    private lateinit var progressBar: ProgressBar
    private lateinit var tvLog: TextView
    private lateinit var logScroll: ScrollView

    private val gpxBridge = GpxFileImportBridge()
    private lateinit var garminCompanion: ConnectIQGarminCompanion
    private var loadedRoute: RoutePackage? = null
    private var mapServer: MapTileServer? = null

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

        btnSend.isEnabled = false

        btnImport.setOnClickListener { pickGpxFile() }
        btnSend.setOnClickListener { sendRoute() }
        findViewById<Button>(R.id.btn_clear_log).setOnClickListener { AppLog.clear() }
        findViewById<Button>(R.id.btn_copy_log).setOnClickListener {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("garmiand-log", AppLog.snapshot()))
            Toast.makeText(this, "Log copied", Toast.LENGTH_SHORT).show()
        }

        AppLog.addListener(logListener)
        AppLog.i(TAG, "App started")

        startMapServer()

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

    private fun startMapServer() {
        try {
            mapServer = MapTileServer(MAP_SERVER_PORT).also { it.start() }
            val ip = NetworkUtil.getLocalIp() ?: "?"
            AppLog.i(TAG, "Map server up at http://$ip:$MAP_SERVER_PORT (also 127.0.0.1)")
        } catch (e: Exception) {
            AppLog.e(TAG, "Failed to start map server", e)
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
        btnSend.isEnabled = false
        progressBar.visibility = View.VISIBLE
        progressBar.progress = 0
        AppLog.i(TAG, "sendRoute: pts=${route.points.size}")

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
            val mapResult = if (result is SyncResult.Ok) sendMapUrl(route) else null
            runOnUiThread {
                progressBar.visibility = View.GONE
                btnSend.isEnabled = true
                tvStatus.text = when (result) {
                    is SyncResult.Ok -> "Sent OK (${result.ackCount} msgs)" +
                        if (mapResult == true) " + map" else " (map failed)"
                    is SyncResult.Failed -> "Failed: ${result.reason}"
                }
            }
        }.start()
    }

    private fun sendMapUrl(route: RoutePackage): Boolean {
        if (route.points.isEmpty()) return false

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
        val padLat = (maxLat - minLat).coerceAtLeast(0.001) * BBOX_PADDING_FRACTION
        val padLon = (maxLon - minLon).coerceAtLeast(0.001) * BBOX_PADDING_FRACTION
        val pMinLat = minLat - padLat
        val pMaxLat = maxLat + padLat
        val pMinLon = minLon - padLon
        val pMaxLon = maxLon + padLon
        val tile = TileComposer.singleTileForBbox(pMinLat, pMaxLat, pMinLon, pMaxLon)
        val mapBbox = tile.bbox

        val url = "https://tile.openstreetmap.org/${tile.zoom}/${tile.x}/${tile.y}.png"
        val msg = SyncMessage.MapUrl(
            sessionId = UUID.randomUUID().toString(),
            url = url,
            minLat = mapBbox.minLat,
            maxLat = mapBbox.maxLat,
            minLon = mapBbox.minLon,
            maxLon = mapBbox.maxLon,
            width = MAP_WIDTH,
            height = MAP_HEIGHT,
        )
        AppLog.i(TAG, "Sending map_url tile=z${tile.zoom}/${tile.x}/${tile.y}: $url")
        val ack = garminCompanion.send(msg)
        AppLog.i(TAG, "map_url ack ok=${ack.ok} reason=${ack.reason}")
        return ack.ok
    }

    override fun onDestroy() {
        super.onDestroy()
        AppLog.removeListener(logListener)
        garminCompanion.shutdown()
        mapServer?.stop()
        mapServer = null
    }
}
