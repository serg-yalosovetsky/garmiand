package com.garmiand.map

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.garmiand.util.AppLog
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.sinh
import kotlin.math.tan

private const val TAG = "TileQuantizer"
private const val USER_AGENT = "Garmiand/1.0 (https://github.com/serg-yalosovetsky/garmiand)"
private const val SOURCE_TILE_SIZE = 256
// 128px × 128px × 1 byte/pixel = 16 KB per tile. With maxTilesPerSide=2 → 4 tiles × 16 KB = 64 KB
// per bundle, which leaves headroom under Fenix 7's ~128 KB Application.Storage budget.
private const val DEFAULT_TILE_OUTPUT = 128

data class QuantizedTile(
    val zoom: Int,
    val tileX: Int,
    val tileY: Int,
    val width: Int,
    val height: Int,
    /** Column-major palette indices (one byte per pixel, value 0..63). */
    val pixels: ByteArray,
)

data class QuantizedBundle(
    val minLat: Double,
    val maxLat: Double,
    val minLon: Double,
    val maxLon: Double,
    val tiles: List<QuantizedTile>,
)

object TileQuantizer {

    /** Pick a single zoom that keeps the route in a manageable tile grid. */
    fun chooseZoom(
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        maxTilesPerSide: Int = 2,
    ): Int {
        for (zoom in 16 downTo 1) {
            val (tx0, ty0) = latLonToTileFractional(maxLat, minLon, zoom)
            val (tx1, ty1) = latLonToTileFractional(minLat, maxLon, zoom)
            val nx = floor(tx1).toInt() - floor(tx0).toInt() + 1
            val ny = floor(ty1).toInt() - floor(ty0).toInt() + 1
            if (nx <= maxTilesPerSide && ny <= maxTilesPerSide) {
                return zoom
            }
        }
        return 1
    }

    fun quantize(
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        urlTemplate: String = "https://tile.openstreetmap.org/%d/%d/%d.png",
        outputSize: Int = DEFAULT_TILE_OUTPUT,
        maxTilesPerSide: Int = 2,
    ): QuantizedBundle {
        val zoom = chooseZoom(minLat, maxLat, minLon, maxLon, maxTilesPerSide)
        val (tx0Frac, ty0Frac) = latLonToTileFractional(maxLat, minLon, zoom)
        val (tx1Frac, ty1Frac) = latLonToTileFractional(minLat, maxLon, zoom)
        val ix0 = floor(tx0Frac).toInt()
        val iy0 = floor(ty0Frac).toInt()
        val ix1 = floor(tx1Frac).toInt()
        val iy1 = floor(ty1Frac).toInt()

        val tiles = mutableListOf<QuantizedTile>()
        for (ty in iy0..iy1) {
            for (tx in ix0..ix1) {
                val bmp = fetchTile(urlTemplate, zoom, tx, ty) ?: continue
                val resized = if (bmp.width == outputSize && bmp.height == outputSize) {
                    bmp
                } else {
                    Bitmap.createScaledBitmap(bmp, outputSize, outputSize, true).also {
                        if (it !== bmp) bmp.recycle()
                    }
                }
                val pixels = quantizeBitmap(resized)
                resized.recycle()
                tiles += QuantizedTile(
                    zoom = zoom,
                    tileX = tx,
                    tileY = ty,
                    width = outputSize,
                    height = outputSize,
                    pixels = pixels,
                )
                AppLog.i(TAG, "tile z$zoom/$tx/$ty quantized to ${pixels.size}B")
            }
        }

        // Bundle bbox = the geographic extent of the tile grid we actually fetched.
        val (topLat, leftLon) = tileFractionalToLatLon(ix0.toDouble(), iy0.toDouble(), zoom)
        val (botLat, rightLon) = tileFractionalToLatLon((ix1 + 1).toDouble(), (iy1 + 1).toDouble(), zoom)

        return QuantizedBundle(
            minLat = botLat,
            maxLat = topLat,
            minLon = leftLon,
            maxLon = rightLon,
            tiles = tiles,
        )
    }

    /** Convert ARGB bitmap to column-major palette indices (one byte per pixel). */
    private fun quantizeBitmap(bmp: Bitmap): ByteArray {
        val w = bmp.width
        val h = bmp.height
        val rowMajor = IntArray(w * h)
        bmp.getPixels(rowMajor, 0, w, 0, 0, w, h)
        // Column-major: out[col * h + row] = palette index of input[row * w + col].
        // The watch-side decoder reads in this order, see [TileDecoder.mc].
        val out = ByteArray(w * h)
        for (col in 0 until w) {
            for (row in 0 until h) {
                val argb = rowMajor[row * w + col]
                out[col * h + row] = Palette.nearest(argb).toByte()
            }
        }
        return out
    }

    private fun fetchTile(urlTemplate: String, zoom: Int, x: Int, y: Int): Bitmap? {
        val url = URL(String.format(urlTemplate, zoom, x, y))
        return try {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 8000
                setRequestProperty("User-Agent", USER_AGENT)
            }
            conn.inputStream.use { stream ->
                val bytes = stream.readBytes()
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }
        } catch (e: Exception) {
            AppLog.w(TAG, "fetchTile $zoom/$x/$y failed: ${e.message}")
            null
        }
    }

    fun latLonToTileFractional(lat: Double, lon: Double, zoom: Int): Pair<Double, Double> {
        val latRad = lat * PI / 180.0
        val n = (1 shl zoom).toDouble()
        val x = (lon + 180.0) / 360.0 * n
        val y = (1.0 - ln(tan(latRad) + 1.0 / cos(latRad)) / PI) / 2.0 * n
        return x to y
    }

    fun tileFractionalToLatLon(tx: Double, ty: Double, zoom: Int): Pair<Double, Double> {
        val n = (1 shl zoom).toDouble()
        val lon = tx / n * 360.0 - 180.0
        val lat = Math.toDegrees(atan(sinh(PI * (1.0 - 2.0 * ty / n))))
        return lat to lon
    }
}
