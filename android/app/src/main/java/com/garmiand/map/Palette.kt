package com.garmiand.map

/**
 * Fixed 64-color palette shared between phone (this file) and watch
 * (parsePalette in TileDecoder.mc). Any change here must bump
 * [Palette.VERSION] AND match the watch-side decoder, otherwise old
 * bundles in Application.Storage decode to garbage.
 *
 * Layout: 6×6×6 RGB cube, evenly spaced. Index = r*36 + g*6 + b where
 * r/g/b are 0..5. 216 colors cost the same 1 byte/pixel as the old 64-color
 * cube but banding is far lower — map labels stay legible after quantization.
 */
object Palette {
    const val SIZE = 216
    const val VERSION = 2

    private val LEVELS = intArrayOf(0, 51, 102, 153, 204, 255)

    /** Index 0..215 → packed 0xRRGGBB. */
    val COLORS: IntArray = IntArray(SIZE).also { arr ->
        for (r in 0..5) for (g in 0..5) for (b in 0..5) {
            arr[r * 36 + g * 6 + b] =
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
        // 6×6×6 cube => quantize each channel to 0..5 (step 51, nearest level).
        val ri = quantizeChannel(r)
        val gi = quantizeChannel(g)
        val bi = quantizeChannel(b)
        return ri * 36 + gi * 6 + bi
    }

    /** Nearest of the 6 evenly spaced levels (step 51). */
    private fun quantizeChannel(v: Int): Int = ((v + 25) / 51).coerceIn(0, 5)
}
