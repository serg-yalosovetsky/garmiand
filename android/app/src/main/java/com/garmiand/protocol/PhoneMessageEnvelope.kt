package com.garmiand.protocol

object PhoneMessageEnvelope {
    const val VERSION = 1

    const val KEY_VERSION = "v"
    const val KEY_KIND = "kind"
    const val KEY_SESSION_ID = "session_id"
    const val KEY_ROUTE_ID = "route_id"
    const val KEY_ROUTE_NAME = "route_name"
    const val KEY_CHUNK_INDEX = "chunk_index"
    const val KEY_CHUNK_COUNT = "chunk_count"
    const val KEY_PAYLOAD_B64 = "payload_b64"

    const val KIND_SYNC_START = "sync_start"
    const val KIND_ROUTE_CHUNK = "route_chunk"
    const val KIND_SYNC_FINISH = "sync_finish"
}

typealias PhoneEnvelope = Map<String, Any>
