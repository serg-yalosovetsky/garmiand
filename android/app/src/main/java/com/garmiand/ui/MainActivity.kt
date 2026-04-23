package com.garmiand.ui

import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.garmiand.domain.Marker
import com.garmiand.domain.RoutePackage
import com.garmiand.domain.RoutePoint
import com.garmiand.garmin.LoggingGarminCompanion
import com.garmiand.protocol.JsonRouteChunkEncoder
import com.garmiand.sync.RouteSyncOrchestrator
import com.garmiand.sync.SyncResult

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val textView = TextView(this)
        setContentView(textView)

        val route = RoutePackage(
            routeId = "demo-route-v1",
            name = "Demo route",
            points = listOf(
                RoutePoint(50.4501, 30.5234),
                RoutePoint(50.4510, 30.5240),
                RoutePoint(50.4520, 30.5250),
            ),
            markers = listOf(
                Marker("start", 50.4501, 30.5234, "Start"),
                Marker("finish", 50.4520, 30.5250, "Finish"),
            ),
        )

        val orchestrator = RouteSyncOrchestrator(
            encoder = JsonRouteChunkEncoder(),
            companion = LoggingGarminCompanion(),
        )

        val result = orchestrator.sync(route)
        textView.text = when (result) {
            is SyncResult.Ok -> "V1 sync OK, ack: ${result.ackCount}"
            is SyncResult.Failed -> "V1 sync failed: ${result.reason}"
        }
    }
}
