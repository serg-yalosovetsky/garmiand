# API Contracts

The only "API" is the Connect IQ phone-app message envelope. There is no HTTP server in the active path.

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

### `map_url`
Sent after `sync_finish` is acked. Tells the watch to fetch a map image and how to project the route onto it.

| Key | Type | Notes |
|---|---|---|
| `url` | `String` | Public HTTPS, direct OSM tile (see ADR-003). |
| `min_lat`, `max_lat`, `min_lon`, `max_lon` | `Double` | Geographic bounds of the image — used by `NavigationView.mapLonToX/mapLatToY` to overlay the polyline. |
| `w`, `h` | `Int` | Pixel size of the image as it will appear on the watch (currently 240×240). |

## Acks

Connect IQ acks delivery, not application correctness. `IQMessageStatus.SUCCESS` means the watch received the dictionary, not that it interpreted it. The watch never sends an application-level ack today; observability is via the on-screen banner.

## Versioning

If a key changes meaning or a kind is renamed, bump `v`. The watch should reject unknown `v` rather than silently misinterpret. (Not yet implemented — TODO if a v2 is introduced.)

## `route_full` (debug-only)

`GarmiandApp.onPhoneMessage` also accepts a `route_full` kind that bundles `sync_start + route_chunk + markers + sync_finish` in one message. Used from the simulator's "Phone → Send Message" tester. **Not** sent by the Android companion. Do not rely on it from production code.
