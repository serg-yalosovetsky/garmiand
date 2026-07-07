package com.garmiand.map

/**
 * Fixed 64-color palette shared between phone (this file) and watch
 * (parsePalette in TileDecoder.mc). Any change here must match the watch-side
 * decoder, otherwise old bundles in Application.Storage decode to garbage.
 *
 * Layout: 4×4×4 RGB cube, evenly spaced (levels = 0/85/170/255 per channel).
 * Index = (r shl 4) or (g shl 2) or b where r/g/b are 0..3.
 *
 * ⚠️ Keep this at 64 entries. Target devices fenix7/fenix7x are 64-color MIP
 * displays; Graphics.createBufferedBitmap has *undefined behaviour* when the
 * palette exceeds the device's color count. A 216-color (6×6×6) cube — tried in
 * "Path B" for legibility — rendered every tile as a purple wash (corrupted
 * index→color mapping) because the watch can only show 64 colors anyway. Label
 * legibility must be solved via tile resolution / source, not palette size.
 */
object Palette {
    const val SIZE = 64
    const val VERSION = 2

    private val LEVELS = intArrayOf(0, 85, 170, 255)

    /** Index 0..63 → packed 0xRRGGBB. */
    val COLORS: IntArray = IntArray(SIZE).also { arr ->
        for (r in 0..3) for (g in 0..3) for (b in 0..3) {
            arr[(r shl 4) or (g shl 2) or b] =
                (LEVELS[r] shl 16) or (LEVELS[g] shl 8) or LEVELS[b]
        }
    }

    /** Pack as on-wire RGB888 bytes (length = SIZE * 3). */
    fun toBytes(): ByteArray {
        val out = ByteArray(SIZE * 3)
        for (i in 0 until SIZE) {
            val c = COLORS[i]
            out[i * 3 + 0] = ((c shr 16) and 0xFF).toByte()
            out[i * 3 + 1] = ((c shr 8) and 0xFF).toByte()
            out[i * 3 + 2] = (c and 0xFF).toByte()
        }
        return out
    }

    /** Nearest palette index for an ARGB pixel (alpha ignored). */
    fun nearest(argb: Int): Int {
        val r = (argb shr 16) and 0xFF
        val g = (argb shr 8) and 0xFF
        val b = argb and 0xFF
        return (quantizeChannel(r) shl 4) or (quantizeChannel(g) shl 2) or quantizeChannel(b)
    }

    /** Nearest of the 4 evenly spaced levels (0/85/170/255); thresholds at midpoints. */
    private fun quantizeChannel(v: Int): Int = when {
        v < 43 -> 0
        v < 128 -> 1
        v < 213 -> 2
        else -> 3
    }
}
