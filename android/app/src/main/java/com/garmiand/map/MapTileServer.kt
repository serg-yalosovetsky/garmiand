package com.garmiand.map

import android.util.Log
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream

private const val TAG = "MapTileServer"

class MapTileServer(port: Int = 8081) : NanoHTTPD("0.0.0.0", port) {

    override fun serve(session: IHTTPSession): Response {
        if (session.uri != "/map") {
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not found")
        }
        val params = session.parameters
        val lat = params["lat"]?.firstOrNull()?.toDoubleOrNull()
        val lon = params["lon"]?.firstOrNull()?.toDoubleOrNull()
        val zoom = params["zoom"]?.firstOrNull()?.toIntOrNull() ?: 14
        val w = params["w"]?.firstOrNull()?.toIntOrNull() ?: 240
        val h = params["h"]?.firstOrNull()?.toIntOrNull() ?: 240

        if (lat == null || lon == null) {
            return newFixedLengthResponse(
                Response.Status.BAD_REQUEST,
                "text/plain",
                "Missing lat/lon",
            )
        }

        Log.i(TAG, "compose lat=$lat lon=$lon z=$zoom ${w}x$h")
        val png = TileComposer.composeMap(lat, lon, zoom, w, h)
            ?: return newFixedLengthResponse(
                Response.Status.INTERNAL_ERROR,
                "text/plain",
                "Compose failed",
            )

        return newFixedLengthResponse(
            Response.Status.OK,
            "image/png",
            ByteArrayInputStream(png),
            png.size.toLong(),
        ).apply {
            addHeader("Cache-Control", "no-cache")
            addHeader("Access-Control-Allow-Origin", "*")
        }
    }
}
