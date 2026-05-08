package com.garmiand.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.garmiand.R
import com.garmiand.domain.RoutePackage
import com.garmiand.garmin.ConnectIQGarminCompanion
import com.garmiand.osmand.GpxFileImportBridge
import com.garmiand.protocol.NativeMapEncoder
import com.garmiand.sync.RouteSyncOrchestrator
import com.garmiand.sync.SyncResult

private const val REQUEST_GPX_FILE = 1001

class MainActivity : AppCompatActivity() {

    private lateinit var tvStatus: TextView
    private lateinit var btnImport: Button
    private lateinit var btnSend: Button
    private lateinit var progressBar: ProgressBar

    private val gpxBridge = GpxFileImportBridge()
    private lateinit var garminCompanion: ConnectIQGarminCompanion
    private var loadedRoute: RoutePackage? = null

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

        garminCompanion = ConnectIQGarminCompanion(this)
        tvStatus.text = "Connecting to Garmin..."
        garminCompanion.initialize { ready ->
            runOnUiThread {
                tvStatus.text = if (ready) "Garmin connected" else "Garmin not available"
            }
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
            runOnUiThread {
                progressBar.visibility = View.GONE
                btnSend.isEnabled = true
                tvStatus.text = when (result) {
                    is SyncResult.Ok -> "Sent OK (${result.ackCount} messages)"
                    is SyncResult.Failed -> "Failed: ${result.reason}"
                }
            }
        }.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        garminCompanion.shutdown()
    }
}
