package com.garmiand.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
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
import java.util.UUID

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

    private val gpxBridge = GpxFileImportBridge()
    private lateinit var garminCompanion: ConnectIQGarminCompanion
    private var loadedRoute: RoutePackage? = null
    private var mapServer: MapTileServer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvStatus = findViewById(R.id.tv_status)
        btnImport = findViewById(R.id.btn_import)
        btnSend = findViewById(R.id.btn_send)
        progressBar = findViewById(R.id.progress_bar)

        btnSend.isEnabled = false

        btnImport.setOnClickListener { pickGpxFile() }
        btnSend.setOnClickListener { sendRoute() }

        startMapServer()

        garminCompanion = ConnectIQGarminCompanion(this)
        tvStatus.text = "Connecting to Garmin..."
        garminCompanion.initialize { ready ->
            runOnUiThread {
                tvStatus.text = if (ready) "Garmin connected" else "Garmin not available"
            }
        }
    }

    private fun startMapServer() {
        try {
            mapServer = MapTileServer(MAP_SERVER_PORT).also { it.start() }
            val ip = NetworkUtil.getLocalIp() ?: "?"
            Log.i("MainActivity", "Map server up at http://$ip:$MAP_SERVER_PORT")
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to start map server: ${e.message}")
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
            } else {
                tvStatus.text = "Failed to parse GPX"
            }
        }
    }

    private fun sendRoute() {
        val route = loadedRoute ?: return
        btnSend.isEnabled = false
        progressBar.visibility = View.VISIBLE
        progressBar.progress = 0

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
        val ip = "127.0.0.1"
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
        val centerLat = (pMinLat + pMaxLat) / 2.0
        val centerLon = (pMinLon + pMaxLon) / 2.0
        val zoom = TileComposer.chooseZoomForBbox(pMinLat, pMaxLat, pMinLon, pMaxLon, MAP_WIDTH, MAP_HEIGHT)
        val mapBbox = TileComposer.bboxForViewport(centerLat, centerLon, zoom, MAP_WIDTH, MAP_HEIGHT)

        val url = "http://$ip:$MAP_SERVER_PORT/map?lat=$centerLat&lon=$centerLon&zoom=$zoom&w=$MAP_WIDTH&h=$MAP_HEIGHT"
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
        Log.i("MainActivity", "Sending map_url: $url")
        val ack = garminCompanion.send(msg)
        return ack.ok
    }

    override fun onDestroy() {
        super.onDestroy()
        garminCompanion.shutdown()
        mapServer?.stop()
        mapServer = null
    }
}
