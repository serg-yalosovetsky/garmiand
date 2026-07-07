package com.garmiand.map

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * On-wire format consumed by the watch (TileDecoder.mc) and validated by the
 * backend's magic-number check (server/src/server.js).
 *
 * Layout (all multi-byte integers big-endian, all floats IEEE-754 single):
 *
 *   offset  size  field
 *   0       4     magic = "GMND"
 *   4       1     version = 1
 *   5       1     paletteSize (= [Palette.SIZE], i.e. 64 in v1)
 *   6       2     tileCount (uint16)
 *   8       16    bbox: minLat, maxLat, minLon, maxLon (4 × float32)
 *   24      P*3   palette (P × RGB888)
 *   24+P*3  T*21  tile entries
 *   ...           tile pixel data (column-major, 1 byte per pixel = palette index)
 *
 * Each tile entry (21 bytes):
 *   0     1   zoom
 *   1     4   tileX (uint32)
 *   5     4   tileY (uint32)
 *   9     2   width (uint16)
 *   11    2   height (uint16)
 *   13    4   pixelOffset (uint32, absolute byte offset in blob)
 *   17    4   pixelLength (uint32)
 */
object TileBundleSerializer {
    // v3: per-tile pixel block is RLE (see TileQuantizer.quantizeBitmap) instead of
    // raw 1 byte/pixel — smaller blobs, watch decodes runs directly.
    const val VERSION = 3
    private const val HEADER_FIXED_SIZE = 24
    private const val TILE_ENTRY_SIZE = 21
    private const val MAGIC: Int = 0x474D4E44 // 'G','M','N','D'

    fun serialize(bundle: QuantizedBundle): ByteArray {
        require(bundle.tiles.size <= 0xFFFF) { "tileCount overflow: ${bundle.tiles.size}" }
        val paletteBytes = Palette.toBytes()
        val paletteSize = Palette.SIZE
        val entriesOffset = HEADER_FIXED_SIZE + paletteBytes.size
        val pixelsStart = entriesOffset + bundle.tiles.size * TILE_ENTRY_SIZE
        val totalPixelBytes = bundle.tiles.sumOf { it.pixels.size }
        val totalSize = pixelsStart + totalPixelBytes

        val buf = ByteBuffer.allocate(totalSize).order(ByteOrder.BIG_ENDIAN)
        buf.putInt(MAGIC)
        buf.put(VERSION.toByte())
        buf.put(paletteSize.toByte())
        buf.putShort(bundle.tiles.size.toShort())
        buf.putFloat(bundle.minLat.toFloat())
        buf.putFloat(bundle.maxLat.toFloat())
        buf.putFloat(bundle.minLon.toFloat())
        buf.putFloat(bundle.maxLon.toFloat())
        buf.put(paletteBytes)

        // Tile entries — pixelOffset filled per-tile as we know the running offset.
        var runningPixelOffset = pixelsStart
        for (t in bundle.tiles) {
            buf.put(t.zoom.toByte())
            buf.putInt(t.tileX)
            buf.putInt(t.tileY)
            buf.putShort(t.width.toShort())
            buf.putShort(t.height.toShort())
            buf.putInt(runningPixelOffset)
            buf.putInt(t.pixels.size)
            runningPixelOffset += t.pixels.size
        }

        for (t in bundle.tiles) {
            buf.put(t.pixels)
        }

        return buf.array()
    }
}
