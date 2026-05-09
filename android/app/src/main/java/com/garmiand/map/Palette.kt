package com.garmiand.map

/**
 * Fixed 64-color palette shared between phone (this file) and watch
 * (parsePalette in TileDecoder.mc). Any change here must bump
 * [Palette.VERSION] AND match the watch-side decoder, otherwise old
 * bundles in Application.Storage decode to garbage.
 *
 * Layout: 4×4×4 RGB cube, evenly spaced. Index = (r << 4) | (g << 2) | b
 * where r/g/b are 0..3.
 */
object Palette {
    const val SIZE = 64
    const val VERSION = 1

    /** Index 0..63 → packed 0xRRGGBB. */
    val COLORS: IntArray = IntArray(SIZE).also { arr ->
        val levels = intArrayOf(0, 85, 170, 255)
        for (r in 0..3) for (g in 0..3) for (b in 0..3) {
            arr[(r shl 4) or (g shl 2) or b] =
                (levels[r] shl 16) or (levels[g] shl 8) or levels[b]
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
        // 4×4×4 cube => quantize each channel to 0..3 by dividing by 64
        // (255/3 ≈ 85 step → bucket boundaries at 42, 127, 212).
        val ri = quantizeChannel(r)
        val gi = quantizeChannel(g)
        val bi = quantizeChannel(b)
        return (ri shl 4) or (gi shl 2) or bi
    }

    private fun quantizeChannel(v: Int): Int = when {
        v < 42 -> 0
        v < 127 -> 1
        v < 212 -> 2
        else -> 3
    }
}
