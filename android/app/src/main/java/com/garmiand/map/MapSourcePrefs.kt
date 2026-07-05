package com.garmiand.map

import android.content.Context

/**
 * Persisted choice of tile source, shared between the manual "Send map" path
 * (MainActivity) and the background auto-fetch path (MapRequestResponder).
 *
 * Two sources are supported:
 *   - Bing Hybrid ([BING_HYBRID_URL]) — satellite imagery with roads+labels baked
 *     in; reads better for orientation ("with names").
 *   - OSM ([OSM_URL]) — plain vector-rendered raster.
 *
 * Default is Bing Hybrid.
 */
object MapSourcePrefs {
    private const val PREFS = "garmiand"
    private const val KEY_BING = "map_source_bing"

    fun useBing(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_BING, true)

    fun setUseBing(context: Context, bing: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_BING, bing).apply()
    }

    /** URL template for the currently selected source. */
    fun urlTemplate(context: Context): String =
        if (useBing(context)) BING_HYBRID_URL else OSM_URL

    fun label(context: Context): String =
        if (useBing(context)) "Bing Hybrid" else "OSM"
}
