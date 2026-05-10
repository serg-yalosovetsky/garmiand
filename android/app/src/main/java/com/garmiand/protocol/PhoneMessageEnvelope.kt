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

    // Tile bundle delivery (HTTPS announcement)
    const val KEY_BUNDLE_ID = "bundle_id"
    const val KEY_DOWNLOAD_URL = "download_url"
    const val KEY_TOTAL_BYTES = "total_bytes"

    // BLE chunked delivery
    const val KEY_CHUNK_INDEX = "i"
    const val KEY_CHUNK_TOTAL = "n"
    const val KEY_CHUNK_TOTAL_BYTES = "tb"
    const val KEY_CHUNK_PAYLOAD = "p"

    const val KIND_SYNC_START = "sync_start"
    const val KIND_ROUTE_CHUNK = "route_chunk"
    const val KIND_MARKERS = "markers"
    const val KIND_SYNC_FINISH = "sync_finish"
    const val KIND_TILE_SESSION = "tile_session"
    const val KIND_TILE_CHUNK = "tile_chunk"

    // BLE resumable transfer handshake
    const val KIND_BLE_BUNDLE_START = "ble_bundle_start"
    const val KIND_BLE_WIP_REPORT = "ble_wip_report"   // watch → phone
    const val KEY_RECEIVED_INDICES = "received_indices" // List<Int> in ble_wip_report
}

typealias PhoneEnvelope = Map<String, Any>
