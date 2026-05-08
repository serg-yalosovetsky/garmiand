package com.garmiand.protocol

object PhoneMessageEnvelope {
    const val VERSION = 1

    const val KEY_VERSION = "v"
    const val KEY_KIND = "kind"
    const val KEY_SESSION_ID = "session_id"
    const val KEY_ROUTE_ID = "route_id"
    const val KEY_ROUTE_NAME = "route_name"
    const val KEY_CHUNK_IDX = "chunk_idx"
    const val KEY_CHUNK_COUNT = "chunk_count"
    const val KEY_LATS = "lats"
    const val KEY_LONS = "lons"
    const val KEY_MARKERS = "markers"
    const val KEY_POINT_COUNT = "point_count"

    // Marker sub-keys
    const val KEY_MARKER_ID = "id"
    const val KEY_MARKER_LAT = "lat"
    const val KEY_MARKER_LON = "lon"
    const val KEY_MARKER_TITLE = "title"

    const val KIND_SYNC_START = "sync_start"
    const val KIND_ROUTE_CHUNK = "route_chunk"
    const val KIND_MARKERS = "markers"
    const val KIND_SYNC_FINISH = "sync_finish"
}

typealias PhoneEnvelope = Map<String, Any>
