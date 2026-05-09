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
| `bundle_id` | `String` | UUID, persisted into `last_bundle_id` Property and used as the `Application.Storage` key prefix (`b_<first8chars>_*`). |
| `download_url` | `String` | Public HTTPS base URL. Watch appends `/chunk?offset=N&size=10240` for each slice. |
| `total_bytes` | `Int` | Total blob size in bytes. Watch pre-allocates a `ByteArray` of this size to avoid heap fragmentation from repeated `addAll`. If absent, the watch falls back to dynamic growth. |

### `tile_chunk` *(BLE bundle delivery, fallback when phone is offline)*
Phone splits a serialized `GMND` bundle (see [MAP_RENDERING.md](MAP_RENDERING.md))
into ≤3000-byte chunks and sends them in order. Watch reassembles in
`BleChunkAssembler` indexed by `i`, so out-of-order arrival is safe.

| Key | Type | Notes |
|---|---|---|
| `bundle_id` | `String` | Identifies which bundle the chunks belong to. New `bundle_id` resets the assembler. |
| `i` | `Int` | 0-based chunk index. |
| `n` | `Int` | Total chunk count. Watch persists once it has all of them. |
| `p` | `ByteArray` | Raw bytes — Connect IQ Mobile SDK converts to `Lang.ByteArray` on the watch. |

## Acks

Connect IQ acks delivery, not application correctness. `IQMessageStatus.SUCCESS` means the watch received the dictionary, not that it interpreted it. The watch never sends an application-level ack today; observability is via the on-screen banner.

## Versioning

If a key changes meaning or a kind is renamed, bump `v`. The watch should reject unknown `v` rather than silently misinterpret. (Not yet implemented — TODO if a v2 is introduced.)

## `route_full` (debug-only)

`GarmiandApp.onPhoneMessage` also accepts a `route_full` kind that bundles `sync_start + route_chunk + markers + sync_finish` in one message. Used from the simulator's "Phone → Send Message" tester. **Not** sent by the Android companion. Do not rely on it from production code.
