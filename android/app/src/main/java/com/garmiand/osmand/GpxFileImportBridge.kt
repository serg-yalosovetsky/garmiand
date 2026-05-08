package com.garmiand.osmand

import android.content.Context
import android.net.Uri
import com.garmiand.domain.Marker
import com.garmiand.domain.RoutePackage
import com.garmiand.domain.RoutePoint
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.InputStream
import java.util.UUID

class GpxFileImportBridge {

    fun loadFromUri(context: Context, uri: Uri, routeName: String? = null): RoutePackage? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                val name = routeName
                    ?: uri.lastPathSegment?.removeSuffix(".gpx")?.removeSuffix(".GPX")
                    ?: "Route"
                parseGpx(stream, name)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun parseGpx(stream: InputStream, name: String): RoutePackage {
        val factory = XmlPullParserFactory.newInstance()
        val parser = factory.newPullParser()
        parser.setInput(stream, "UTF-8")

        val points = mutableListOf<RoutePoint>()
        val waypoints = mutableListOf<Marker>()

        var inWpt = false
        var inWptName = false
        var wptIdx = 0
        var wptLat = 0.0
        var wptLon = 0.0
        var wptName = ""

        var eventType = parser.eventType
        while (eventType != XmlPullParser.END_DOCUMENT) {
            when (eventType) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "trkpt" -> {
                        val lat = parser.getAttributeValue(null, "lat")?.toDoubleOrNull()
                        val lon = parser.getAttributeValue(null, "lon")?.toDoubleOrNull()
                        if (lat != null && lon != null) {
                            points += RoutePoint(lat, lon)
                        }
                    }
                    "wpt" -> {
                        inWpt = true
                        wptLat = parser.getAttributeValue(null, "lat")?.toDoubleOrNull() ?: 0.0
                        wptLon = parser.getAttributeValue(null, "lon")?.toDoubleOrNull() ?: 0.0
                        wptName = ""
                        wptIdx++
                    }
                    "name" -> if (inWpt) inWptName = true
                }
                XmlPullParser.TEXT -> if (inWptName) {
                    wptName += parser.text
                }
                XmlPullParser.END_TAG -> when (parser.name) {
                    "name" -> inWptName = false
                    "wpt" -> {
                        waypoints += Marker(
                            id = "wpt-$wptIdx",
                            lat = wptLat,
                            lon = wptLon,
                            title = wptName.trim().ifBlank { "Waypoint $wptIdx" },
                        )
                        inWpt = false
                    }
                }
            }
            eventType = parser.next()
        }

        val markers = buildList {
            if (points.isNotEmpty()) {
                add(Marker("start", points.first().lat, points.first().lon, "Start"))
            }
            addAll(waypoints)
            if (points.size > 1) {
                add(Marker("finish", points.last().lat, points.last().lon, "Finish"))
            }
        }

        return RoutePackage(
            routeId = UUID.randomUUID().toString(),
            name = name,
            points = points,
            markers = markers,
        )
    }
}
