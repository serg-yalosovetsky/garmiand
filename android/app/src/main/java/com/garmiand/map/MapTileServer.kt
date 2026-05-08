package com.garmiand.map

import com.garmiand.util.AppLog
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream

private const val TAG = "MapTileServer"

class MapTileServer(port: Int = 8081) : NanoHTTPD("0.0.0.0", port) {

    override fun serve(session: IHTTPSession): Response {
        AppLog.i(TAG, "HTTP ${session.method} ${session.uri} from ${session.headers["remote-addr"]} ua=${session.headers["user-agent"]}")
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
            AppLog.w(TAG, "missing lat/lon: $params")
            return newFixedLengthResponse(
                Response.Status.BAD_REQUEST,
                "text/plain",
                "Missing lat/lon",
            )
        }

        AppLog.i(TAG, "compose lat=$lat lon=$lon z=$zoom ${w}x$h")
        val png = TileComposer.composeMap(lat, lon, zoom, w, h)
            ?: run {
                AppLog.e(TAG, "composeMap returned null")
                return newFixedLengthResponse(
                    Response.Status.INTERNAL_ERROR,
                    "text/plain",
                    "Compose failed",
                )
            }
        AppLog.i(TAG, "compose OK size=${png.size}B")

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
