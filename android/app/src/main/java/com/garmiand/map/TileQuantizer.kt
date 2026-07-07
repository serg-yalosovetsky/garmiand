package com.garmiand.map

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.garmiand.domain.RoutePoint
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

// Tile sources. OSM is plain vector-rendered raster (labels shrink to mush after
// downscale+quantize). Bing Hybrid is satellite imagery with roads+labels baked in
// ("it=A,G,L"), which reads better for orientation. Bing uses a quadkey path (not
// z/x/y): "{q}" → Bing quadkey, "{s}" → server 1..3. Scheme taken from SAS.Planet's
// Bing_Sat_BE_H.zmp; https avoids Android's cleartext-http block.
const val OSM_URL = "https://tile.openstreetmap.org/%d/%d/%d.png"
// http (not https) on purpose: the Bing CDN is fronted by Akamai whose TLS cert
// omits virtualearth.net from its SAN, so HTTPS fails Android's hostname check on
// every tile. SAS.Planet fetches these over plain http too. Cleartext is permitted
// for this domain only via res/xml/network_security_config.xml; everything else
// (OSM etc.) stays https.
const val BING_HYBRID_URL =
    "http://ak.dynamic.t{s}.tiles.virtualearth.net/comp/ch/{q}?mkt=ru-RU&it=A,G,L&shading=hill&og=8&n=z"
// Active default source for all bundle builds.
val DEFAULT_TILE_URL = BING_HYBRID_URL
private const val SOURCE_TILE_SIZE = 256
// 128px × 128px × 1 byte/pixel = 16 KB per tile. Corridor approach at zoom 13 yields
// ~10–15 tiles (160–240 KB) for a 20 km route — well within LRU-cached App.Storage.
private const val DEFAULT_TILE_OUTPUT = 128
// Safety cap: blob + decoded bitmaps must fit in watch RAM (~678 KB free on fenix 7).
// 24 tiles × 16 KB × 2 (blob + bitmaps) = 768 KB — at this cap we're near the limit.
private const val MAX_CORRIDOR_TILES = 20

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

/** Per-zoom fetch plan for [TileQuantizer.quantizeMultiZoom] (destructured inline). */
private data class ZoomPlan(
    val bufferMeters: Double,
    val maxTiles: Int,
    val outputPx: Int,
    val sharpDownscale: Boolean,
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
        urlTemplate: String = DEFAULT_TILE_URL,
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

    /**
     * Corridor-based tile selection: collect every tile within [bufferMeters] of any route
     * point at a fixed [zoom], then download and quantize only those tiles.
     *
     * Compared to the bbox approach, this avoids downloading large empty areas for
     * winding routes — a 20 km hiking route at zoom 13 with 300 m buffer typically
     * yields 10–15 tiles (160–240 KB) instead of the bbox 4-tile grid at low zoom.
     */
    fun quantizeCorridor(
        points: List<RoutePoint>,
        bufferMeters: Double = 300.0,
        zoom: Int = 13,
        urlTemplate: String = DEFAULT_TILE_URL,
        outputSize: Int = DEFAULT_TILE_OUTPUT,
        maxTiles: Int = MAX_CORRIDOR_TILES,
        // Bilinear (true) averages neighbours — smooth for heavy overview
        // downscale, but blurs thin label strokes into the background. Set false
        // (nearest-neighbour) at street/detail zooms to keep label edges hard.
        // Ignored when outputSize == SOURCE_TILE_SIZE (no scaling happens).
        filterDownscale: Boolean = true,
    ): QuantizedBundle {
        require(points.isNotEmpty()) { "No route points" }

        val tileCoords = mutableSetOf<Pair<Int, Int>>()
        for (pt in points) {
            val bufLat = bufferMeters / 111_000.0
            val bufLon = bufferMeters / (111_000.0 * cos(pt.lat * PI / 180.0))

            val (tx0Frac, ty0Frac) = latLonToTileFractional(pt.lat + bufLat, pt.lon - bufLon, zoom)
            val (tx1Frac, ty1Frac) = latLonToTileFractional(pt.lat - bufLat, pt.lon + bufLon, zoom)

            for (ty in floor(ty0Frac).toInt()..floor(ty1Frac).toInt()) {
                for (tx in floor(tx0Frac).toInt()..floor(tx1Frac).toInt()) {
                    tileCoords.add(tx to ty)
                }
            }
        }

        val sorted = tileCoords.sortedWith(compareBy({ it.second }, { it.first }))
        val capped = if (sorted.size > maxTiles) {
            AppLog.w(TAG, "corridor: ${sorted.size} tiles exceeds cap $maxTiles — truncating")
            sorted.take(maxTiles)
        } else sorted
        AppLog.i(TAG, "corridor: ${capped.size} tiles at z$zoom buffer=${bufferMeters.toInt()}m")

        val tiles = mutableListOf<QuantizedTile>()
        for ((tx, ty) in capped) {
            val bmp = fetchTile(urlTemplate, zoom, tx, ty) ?: continue
            val resized = if (bmp.width == outputSize && bmp.height == outputSize) bmp
                else Bitmap.createScaledBitmap(bmp, outputSize, outputSize, filterDownscale)
                    .also { if (it !== bmp) bmp.recycle() }
            val pixels = quantizeBitmap(resized)
            resized.recycle()
            tiles += QuantizedTile(zoom, tx, ty, outputSize, outputSize, pixels)
            AppLog.i(TAG, "tile z$zoom/$tx/$ty quantized to ${pixels.size}B")
        }
        if (tiles.isEmpty()) throw IllegalStateException("No tiles fetched for corridor")

        val allTx = tiles.map { it.tileX }
        val allTy = tiles.map { it.tileY }
        val (topLat, leftLon) = tileFractionalToLatLon(allTx.min().toDouble(), allTy.min().toDouble(), zoom)
        val (botLat, rightLon) = tileFractionalToLatLon((allTx.max() + 1).toDouble(), (allTy.max() + 1).toDouble(), zoom)
        return QuantizedBundle(minLat = botLat, maxLat = topLat, minLon = leftLon, maxLon = rightLon, tiles = tiles)
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

    // Bing quadkey: interleave x/y bits from the most significant down. Digit per
    // level = (x bit) + 2*(y bit). Matches SAS.Planet's Bing_Sat_BE_H GetUrlScript.
    private fun quadKey(x: Int, y: Int, zoom: Int): String {
        val sb = StringBuilder(zoom)
        for (i in zoom downTo 1) {
            var digit = 0
            val mask = 1 shl (i - 1)
            if (x and mask != 0) digit += 1
            if (y and mask != 0) digit += 2
            sb.append(digit)
        }
        return sb.toString()
    }

    // Resolve a tile template to a concrete URL. "{q}" → Bing quadkey scheme
    // (with "{s}" server 1..3); otherwise the classic printf z/x/y form.
    private fun buildTileUrl(urlTemplate: String, zoom: Int, x: Int, y: Int): String {
        return if (urlTemplate.contains("{q}")) {
            urlTemplate
                .replace("{q}", quadKey(x, y, zoom))
                .replace("{s}", (1..3).random().toString())
        } else {
            String.format(urlTemplate, zoom, x, y)
        }
    }

    private fun fetchTile(urlTemplate: String, zoom: Int, x: Int, y: Int): Bitmap? {
        val url = URL(buildTileUrl(urlTemplate, zoom, x, y))
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

    /**
     * Fetch corridor tiles at multiple OSM zoom levels and merge into one bundle.
     *
     * The watch picks exactly one of three levels to render, keyed off the
     * viewport zoom factor (NavigationView.checkZoomSwitch): zooms[0] when
     * zoomed out, the level nearest the default target at normal scale,
     * zooms.last() when zoomed in. The set is spread so all three buckets
     * resolve to distinct, useful levels, and the default (mid) is a legible
     * street zoom rather than a coarse overview.
     *
     * Per-level settings (buf=bufferMeters, cap=maxTiles, size=outputPx, sharp=nearest-neighbour):
     *   z13: buf=400m  cap=3   size=64   smooth — town overview when zoomed out (small)
     *   z15: buf=250m  cap=6   size=128  sharp  — street DEFAULT view (256px native OOM'd the
     *          watch decode → back to 128px; nearest-neighbour still sharpens labels a bit)
     *   z17: buf=150m  cap=3   size=128  sharp  — deep detail; nearest-neighbour keeps edges hard
     *
     * Bundle blob estimate: 3×4KB + 6×16KB + 3×16KB ≈ 156 KB. The WHOLE blob is
     * loaded into the Fenix heap at once (TileDecoder.load), and ByteArray.addAll
     * growth peaks ~1.5× — a ~330 KB bundle OOM'd, so the total is kept ≲ 160 KB
     * (≤ 12 storage chunks; the watch refuses anything larger). The watch still
     * decodes only one zoom level at a time (see NavigationView.checkZoomSwitch).
     */
    fun quantizeMultiZoom(
        points: List<RoutePoint>,
        zooms: List<Int> = listOf(13, 15, 17),
        urlTemplate: String = DEFAULT_TILE_URL,
        // Множитель буфера. 1.0 — коридор маршрута; авто-докачка вокруг одной
        // точки использует ~4.0, чтобы одна точка дала осмысленную площадь.
        bufferScale: Double = 1.0,
    ): QuantizedBundle {
        require(points.isNotEmpty()) { "No route points" }
        val allTiles = mutableListOf<QuantizedTile>()
        var minLat = Double.MAX_VALUE
        var maxLat = -Double.MAX_VALUE
        var minLon = Double.MAX_VALUE
        var maxLon = -Double.MAX_VALUE

        for (zoom in zooms) {
            // (buffer, maxTiles, outputPx, sharpDownscale). Budget keeps the whole
            // blob ≤ ~192 KB (12×16 KB) so the watch load guard accepts it:
            //   z13  3×4KB=12KB  ·  z15  2×64KB=128KB  ·  z17  2×16KB=32KB ≈ 172KB.
            // z15 is the default street level (what the user actually reads), so it
            // renders at native 256px (no downscale) with hard label edges. z13 is a
            // coarse overview — smooth downscale is fine and cheap. Caps are the knob
            // to trade coverage vs. clarity; raising any of them risks the 192KB wall.
            val (rawBuf, cap, size, sharp) = when (zoom) {
                13 -> ZoomPlan(400.0, 3, 64, false)   // overview: smooth 256→64
                17 -> ZoomPlan(150.0, 3, 128, true)   // deep detail: sharp 256→128
                // z15 streets: 128px. NOT native 256 — 256px tiles OOM'd / stalled
                // the Fenix 7 decode (stuck "dec", no map). Nearest-neighbour still
                // sharpens labels a bit without the memory cost.
                else -> ZoomPlan(250.0, 6, DEFAULT_TILE_OUTPUT, true)
            }
            val buf = rawBuf * bufferScale
            AppLog.i(TAG, "quantizeMultiZoom: z$zoom buf=${buf.toInt()}m cap=$cap size=${size}px sharp=$sharp")
            val bundle = try {
                quantizeCorridor(points, bufferMeters = buf, zoom = zoom, urlTemplate = urlTemplate, outputSize = size, maxTiles = cap, filterDownscale = !sharp)
            } catch (e: Exception) {
                AppLog.w(TAG, "quantizeMultiZoom z$zoom failed: ${e.message}")
                continue
            }
            allTiles += bundle.tiles
            if (bundle.minLat < minLat) minLat = bundle.minLat
            if (bundle.maxLat > maxLat) maxLat = bundle.maxLat
            if (bundle.minLon < minLon) minLon = bundle.minLon
            if (bundle.maxLon > maxLon) maxLon = bundle.maxLon
        }

        if (allTiles.isEmpty()) throw IllegalStateException("No tiles fetched for any zoom level")
        AppLog.i(TAG, "quantizeMultiZoom: ${allTiles.size} total tiles across ${zooms.size} zoom levels")
        return QuantizedBundle(minLat = minLat, maxLat = maxLat, minLon = minLon, maxLon = maxLon, tiles = allTiles)
    }
}
