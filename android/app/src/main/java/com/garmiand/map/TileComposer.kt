package com.garmiand.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.util.Log
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.sinh
import kotlin.math.tan

private const val TAG = "TileComposer"
private const val TILE_SIZE = 256
private const val USER_AGENT = "Garmiand/1.0 (https://github.com/serg-yalosovetsky/garmiand)"
private const val OSM_TEMPLATE = "https://tile.openstreetmap.org/%d/%d/%d.png"

object TileComposer {

    private val tileCache = ConcurrentHashMap<String, ByteArray>()

    fun composeMap(
        centerLat: Double,
        centerLon: Double,
        zoom: Int,
        outWidth: Int,
        outHeight: Int,
    ): ByteArray? {
        val (cTileXFrac, cTileYFrac) = latLonToTileFractional(centerLat, centerLon, zoom)
        val cPxX = cTileXFrac * TILE_SIZE
        val cPxY = cTileYFrac * TILE_SIZE

        val halfW = outWidth / 2.0
        val halfH = outHeight / 2.0
        val originPxX = cPxX - halfW
        val originPxY = cPxY - halfH

        val firstTileX = floor(originPxX / TILE_SIZE).toInt()
        val firstTileY = floor(originPxY / TILE_SIZE).toInt()
        val lastTileX = floor((originPxX + outWidth) / TILE_SIZE).toInt()
        val lastTileY = floor((originPxY + outHeight) / TILE_SIZE).toInt()

        val canvasW = (lastTileX - firstTileX + 1) * TILE_SIZE
        val canvasH = (lastTileY - firstTileY + 1) * TILE_SIZE
        val canvasBitmap = Bitmap.createBitmap(canvasW, canvasH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(canvasBitmap)

        val maxTile = (1 shl zoom) - 1
        for (ty in firstTileY..lastTileY) {
            for (tx in firstTileX..lastTileX) {
                val wrappedX = ((tx % (maxTile + 1)) + (maxTile + 1)) % (maxTile + 1)
                val tileBitmap = if (ty < 0 || ty > maxTile) {
                    null
                } else {
                    fetchTile(zoom, wrappedX, ty)
                }
                val dstLeft = (tx - firstTileX) * TILE_SIZE
                val dstTop = (ty - firstTileY) * TILE_SIZE
                if (tileBitmap != null) {
                    canvas.drawBitmap(tileBitmap, dstLeft.toFloat(), dstTop.toFloat(), null)
                    tileBitmap.recycle()
                }
            }
        }

        val cropLeft = (originPxX - firstTileX * TILE_SIZE).toInt().coerceAtLeast(0)
        val cropTop = (originPxY - firstTileY * TILE_SIZE).toInt().coerceAtLeast(0)
        val cropW = outWidth.coerceAtMost(canvasW - cropLeft)
        val cropH = outHeight.coerceAtMost(canvasH - cropTop)
        val cropped = Bitmap.createBitmap(canvasBitmap, cropLeft, cropTop, cropW, cropH)
        canvasBitmap.recycle()

        val output = if (cropped.width != outWidth || cropped.height != outHeight) {
            val scaled = Bitmap.createScaledBitmap(cropped, outWidth, outHeight, true)
            cropped.recycle()
            scaled
        } else {
            cropped
        }

        val baos = ByteArrayOutputStream()
        output.compress(Bitmap.CompressFormat.PNG, 90, baos)
        output.recycle()
        return baos.toByteArray()
    }

    private fun fetchTile(zoom: Int, x: Int, y: Int): Bitmap? {
        val key = "$zoom/$x/$y"
        tileCache[key]?.let { return decode(it) }

        val url = URL(String.format(OSM_TEMPLATE, zoom, x, y))
        return try {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 8000
                setRequestProperty("User-Agent", USER_AGENT)
            }
            conn.inputStream.use { stream ->
                val bytes = stream.readBytes()
                if (tileCache.size > 64) tileCache.clear()
                tileCache[key] = bytes
                decode(bytes)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch tile $key: ${e.message}")
            null
        }
    }

    private fun decode(bytes: ByteArray): Bitmap? = try {
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    } catch (_: Exception) {
        null
    }

    private fun latLonToTileFractional(lat: Double, lon: Double, zoom: Int): Pair<Double, Double> {
        val latRad = lat * PI / 180.0
        val n = (1 shl zoom).toDouble()
        val x = (lon + 180.0) / 360.0 * n
        val y = (1.0 - ln(tan(latRad) + 1.0 / cos(latRad)) / PI) / 2.0 * n
        return x to y
    }

    private fun tileFractionalToLatLon(tx: Double, ty: Double, zoom: Int): Pair<Double, Double> {
        val n = (1 shl zoom).toDouble()
        val lon = tx / n * 360.0 - 180.0
        val lat = Math.toDegrees(atan(sinh(PI * (1.0 - 2.0 * ty / n))))
        return lat to lon
    }

    fun bboxForViewport(
        centerLat: Double, centerLon: Double, zoom: Int, width: Int, height: Int,
    ): MapBbox {
        val (cTx, cTy) = latLonToTileFractional(centerLat, centerLon, zoom)
        val cPxX = cTx * TILE_SIZE
        val cPxY = cTy * TILE_SIZE
        val originPxX = cPxX - width / 2.0
        val originPxY = cPxY - height / 2.0
        val cornerPxX = originPxX + width
        val cornerPxY = originPxY + height
        val (topLat, leftLon) = tileFractionalToLatLon(originPxX / TILE_SIZE, originPxY / TILE_SIZE, zoom)
        val (botLat, rightLon) = tileFractionalToLatLon(cornerPxX / TILE_SIZE, cornerPxY / TILE_SIZE, zoom)
        return MapBbox(
            minLat = botLat,
            maxLat = topLat,
            minLon = leftLon,
            maxLon = rightLon,
        )
    }

    fun chooseZoomForBbox(
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        targetW: Int, targetH: Int,
    ): Int {
        for (zoom in 18 downTo 1) {
            val (minX, minY) = latLonToTileFractional(maxLat, minLon, zoom)
            val (maxX, maxY) = latLonToTileFractional(minLat, maxLon, zoom)
            val pxW = (maxX - minX) * TILE_SIZE
            val pxH = (maxY - minY) * TILE_SIZE
            if (pxW <= targetW && pxH <= targetH) {
                return zoom
            }
        }
        return 1
    }
}

data class MapBbox(
    val minLat: Double,
    val maxLat: Double,
    val minLon: Double,
    val maxLon: Double,
)
