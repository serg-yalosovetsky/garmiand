# API Contracts

Two APIs: the Connect IQ phone-app message envelope (BLE) and the bundle
broker REST API (HTTPS, see [BACKEND.md](BACKEND.md) for the latter).

## Envelope

Every message is a `Map<String, Any>` (Kotlin) serialized to a `Lang.Dictionary` on the watch. Keys are `String`. The schema is centralized in [PhoneMessageEnvelope.kt](../android/app/src/main/java/com/garmiand/protocol/PhoneMessageEnvelope.kt).

Common keys:
- `v: Int = 1` — protocol version
- `kind: String` — message discriminator
- `session_id: String` — UUID per sync attempt

## Message Kinds

### `sync_start`
Begins a sync. Resets watch state.

| Key | Type | Notes |
|---|---|---|
| `route_id` | `String` | |
| `route_name` | `String` | Displayed at top of watch screen, truncated with `...` to fit. |
| `chunk_count` | `Int` | Drives the "syncing X%" status. |

### `route_chunk`
One slice of points. Encoder default is 50 points/chunk to stay under the ~4 KB Connect IQ limit.

| Key | Type | Notes |
|---|---|---|
| `chunk_idx` | `Int` | 0-based. |
| `lats` | `List<Double>` | Doubles on the wire; `RouteData` casts to `Float`. |
| `lons` | `List<Double>` | |

### `markers`
Sent once after all chunks. May be omitted if the route has no markers.

| Key | Type | Notes |
|---|---|---|
| `markers` | `List<Map<String, Any>>` | Each: `{id, lat, lon, title}` (string keys: `id`, `lat`, `lon`, `title`). |

### `sync_finish`
Marks the route complete. The watch flips `RouteData.isComplete = true` and switches off the waiting screen.

| Key | Type | Notes |
|---|---|---|
| `route_id` | `String` | |
| `point_count` | `Int` | For sanity check / display. |

### `tile_session` *(HTTPS bundle delivery)*
Sent after `sync_finish` is acked **only when the user opted into "Cache map for
offline" and the phone has internet**. Tells the watch to fetch a quantized
bundle from our backend in 10 KB chunks.

| Key | Type | Notes |
|---|---|---|
| `bundle_id` | `String` | **CRC32 of the bundle bytes**, formatted as 8 lowercase hex digits (e.g. `"a3f1e7c2"`). Deterministic: same route produces the same bytes → same hash → same Storage key. Persisted into `last_bundle_id` Property; used as Storage key prefix `b_<bundle_id>_*`. **Not** the server's session UUID (that is only in `download_url`). |
| `session_id` | `String` | UUID per sync attempt, embedded in `download_url` only. Has no meaning on the watch beyond the URL. |
| `download_url` | `String` | Public HTTPS base URL. Watch appends `/chunk?offset=N&size=10240` for each slice. |
| `total_bytes` | `Int` | Total blob size in bytes. Watch pre-allocates a `ByteArray` of this size to avoid heap fragmentation from repeated `addAll`. If absent, the watch falls back to dynamic growth. |

**Cache check.** Before initiating the HTTPS download, the watch calls
`TileDecoder.exists(bundleId)` (an O(1) Storage probe). If the bundle is
already persisted, the watch activates it immediately (`setBundleId()`) and
skips the entire `makeWebRequest` sequence. The same route re-synced from the
phone produces the same CRC32 hash, so the second sync is a no-op on the watch.

### `tile_chunk` *(BLE bundle delivery, fallback when phone is offline)*
Phone splits a serialized `GMND` bundle (see [MAP_RENDERING.md](MAP_RENDERING.md))
into ≤3072-byte chunks and sends them in order. Watch reassembles in
`BleChunkAssembler` indexed by `i`, so out-of-order arrival is safe.

| Key | Type | Notes |
|---|---|---|
| `bundle_id` | `String` | Identifies which bundle the chunks belong to. New `bundle_id` resets the assembler. |
| `i` | `Int` | 0-based chunk index. |
| `n` | `Int` | Total chunk count. Watch persists once it has all of them. |
| `tb` | `Int` | Total bundle size in bytes. Watch pre-allocates a single `ByteArray` of this size on the first chunk, avoiding N² heap churn from repeated `addAll`. If missing, the assembler falls back to dynamic growth. |
| `p` | `ByteArray` | Raw bytes — Connect IQ Mobile SDK converts to `Lang.ByteArray` on the watch. |

### `ble_bundle_start` *(resumable BLE handshake, phone → watch)*

Sent by the phone **before** starting a BLE `tile_chunk` sequence. The watch
checks its WIP Storage for matching `bundle_id` and replies with `ble_wip_report`.

| Key | Type | Notes |
|---|---|---|
| `bundle_id` | `String` | CRC32 of the bundle bytes (8 hex chars). Same format as `tile_session.bundle_id`. |
| `n` | `Int` | Total chunk count for this bundle. |
| `tb` | `Int` | Total bundle size in bytes. |

### `ble_wip_report` *(resumable BLE handshake, watch → phone)*

Sent by the watch in response to `ble_bundle_start`. Phone waits up to 3 s
(via `CountDownLatch`) before assuming no WIP and starting from chunk 0.

| Key | Type | Notes |
|---|---|---|
| `bundle_id` | `String` | Echo of the bundle being transferred. |
| `received_indices` | `List<Int>` | Chunk indices already on the watch. Empty list = no WIP (send everything from 0). **Full list `[0..N-1]` means the bundle is already fully persisted** — phone skips all chunks and the transfer completes instantly. |

**Flow.** Phone sends `ble_bundle_start` → watch checks in this order:

1. **WIP assembler exists** for the same `bundle_id` → transmit WIP indices.
2. **No WIP but bundle fully persisted** (`TileDecoder.exists()` returns true) →
   transmit `[0, 1, …, N-1]` (all indices). Watch also calls `setBundleId()` to
   activate the cached bundle immediately.
3. **WIP for a different `bundle_id`** → clear old WIP, transmit empty list.
4. **No WIP, not persisted** → transmit empty list (send everything).

In all cases the phone skips any index in `received_indices`, so case 2 results
in zero chunks transferred.

**WIP Storage keys** (watch, prefix `ble_wip_`):

| Key | Type | Content |
|---|---|---|
| `ble_wip_id` | String | bundle ID |
| `ble_wip_tot` | Number | total chunk count |
| `ble_wip_sz` | Number | total bytes |
| `ble_wip_csz` | Number | chunk size in bytes |
| `ble_wip_n` | Number | received count so far |
| `ble_wip_c_N` | ByteArray | raw payload for chunk N |

All WIP keys are cleared by `BleChunkAssembler.clearWip()` when the bundle is
fully assembled. On app restart, `BleChunkAssembler.loadWip()` reads these keys
and restores the in-progress assembler.

## Acks

Connect IQ acks delivery, not application correctness. `IQMessageStatus.SUCCESS` means the watch received the dictionary, not that it interpreted it. The watch never sends an application-level ack today; observability is via the on-screen banner.

## Versioning

If a key changes meaning or a kind is renamed, bump `v`. The watch should reject unknown `v` rather than silently misinterpret. (Not yet implemented — TODO if a v2 is introduced.)

## `route_full` (debug-only)

`GarmiandApp.onPhoneMessage` also accepts a `route_full` kind that bundles `sync_start + route_chunk + markers + sync_finish` in one message. Used from the simulator's "Phone → Send Message" tester. **Not** sent by the Android companion. Do not rely on it from production code.
