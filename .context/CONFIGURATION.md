# Configuration

Compile-time constants for the watch and Kotlin side; build-time injection
for backend coordinates on the phone.

## Android — `MainActivity.kt`

| Constant | Value | Meaning |
|---|---|---|
| `BBOX_PADDING_FRACTION` | `0.15` | Padding around the route bbox before tile quantization. |
| `REQUEST_GPX_FILE` | `1001` | `startActivityForResult` request code. |

## Android — BuildConfig (read in `MainActivity` and `MapBundleUploader`)

Set via `gradle.properties` or env vars before assembling. Defaults are
empty (HTTPS path falls back to BLE) and a placeholder token.

| Field | Source | Default | Meaning |
|---|---|---|---|
| `BACKEND_URL` | `garmiand.backendUrl` property / `GARMIAND_BACKEND_URL` env | `""` | Bundle broker base URL. Empty → BLE-only. |
| `BACKEND_TOKEN` | `garmiand.backendToken` property / `GARMIAND_BACKEND_TOKEN` env | `dev-token-change-me` | Bearer auth header. Must match the server's `BACKEND_TOKEN`. |

## Android — `ConnectIQGarminCompanion.kt`

| Constant | Value | Meaning |
|---|---|---|
| `WATCH_APP_ID` | `71DA4029287A447BBE86B83DC1588647` | Must equal `<iq:application id="...">` in `garmin/manifest.xml`. **Change in lockstep.** |
| `SEND_TIMEOUT_MS` | `30000` | Busy-wait deadline for an `IQMessageStatus` callback. Empirical: Garmin BLE acks a ~1.5 KB chunk in 4–6 s, a 3 KB chunk in ~8 s; 30 s gives healthy headroom for any size we send. |

## Android — `NativeMapEncoder.kt`

| Parameter | Default | Meaning |
|---|---|---|
| `pointsPerChunk` | `50` | Points per `route_chunk`. ~800 bytes per chunk; safely under the ~4 KB Connect IQ ceiling. Increase only with measurement. |

## Android — `TileQuantizer.kt`

| Constant | Default | Meaning |
|---|---|---|
| `DEFAULT_TILE_OUTPUT` | `128` | Default output tile pixel size (128×128). Used by `quantizeCorridor` unless overridden. |
| `MAX_CORRIDOR_TILES` | `20` | Global cap per `quantizeCorridor()` call. Overridable via the `maxTiles` parameter. |
| `maxTilesPerSide` (param) | `2` | Constrains the bbox tile grid in `quantize()`; `chooseZoom` picks the highest fitting zoom. |

`quantizeMultiZoom()` calls `quantizeCorridor()` three times with per-zoom overrides:

| OSM zoom | `bufferMeters` | `maxTiles` | `outputSize` |
|---|---|---|---|
| 12 | 300 m | 4 | 64 px |
| 13 | 300 m | 12 | 128 px |
| 15 | 150 m | 6 | 128 px |

## Android — `MapBundleBleSender.kt`

| Constant | Default | Meaning |
|---|---|---|
| `DEFAULT_CHUNK_SIZE` | `3072` (3 KB) | Bytes per BLE `tile_chunk`. Garmin per-message limit is ~4 KB; 3 KB leaves headroom. Acks in ~4–8 s on Fenix 7. Adaptive: halved on `FAILURE_MESSAGE_TOO_LARGE`. |
| `MIN_CHUNK_SIZE` | `1024` | Floor for adaptive size reduction. |
| `INTER_CHUNK_DELAY_MS` | `300` | Pause between chunks to keep Garmin's 3-outstanding-request queue from stalling. |
| `MAX_RETRIES` | `4` | Per-chunk retry attempts before aborting the bundle send. |
| `RETRY_BACKOFF_MS` | `2500` | Wait between retries. |
| `MAX_CONTINUOUS_MS` | `120 000` (2 min) | Safety timer: if a single sending pass takes longer than this, pause for `SAFETY_PAUSE_MS`. Prevents starving the watch VM. |
| `SAFETY_PAUSE_MS` | `10 000` (10 s) | How long to pause when `MAX_CONTINUOUS_MS` is exceeded. |
| `WIP_QUERY_TIMEOUT_MS` | `3 000` (3 s) | How long to wait for the watch's `ble_wip_report` after sending `ble_bundle_start`. On timeout, sends all chunks from index 0. |

## Backend — `server/.env`

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `3000` | Listen port. |
| `BACKEND_TOKEN` | `dev-token-change-me` | Required to match the Android side. |
| `DATA_DIR` | `./data` | Where bundle blobs are written. Mount a volume here in production. |
| `RETENTION_DAYS` | `7` | Old bundles deleted hourly. |
| `PUBLIC_URL` | `http://localhost:3000` | Used in the `downloadUrl` returned to phone (and ultimately the watch). |
| `MAX_BUNDLE_BYTES` | `4194304` | 4 MiB upload cap. |

## Watch — `manifest.xml`

| Field | Value | Notes |
|---|---|---|
| `id` | `71DA4029287A447BBE86B83DC1588647` | See above. |
| `entry` | `GarmiandApp` | |
| `type` | `watch-app` | |
| products | `fenix7` | Only target supported today. |
| permissions | `Positioning`, `Communications` | MapView does not need an explicit permission in SDK 9.1.0. |
| minApiLevel | `3.3.0` | |

## Watch — `properties.xml` / Connect IQ Settings

| Property | Type | Default | Meaning |
|---|---|---|---|
| `map_mode` | Number | `0` | 0 = NATIVE (TopoActive), 1 = TILES (custom bundle), 2 = NONE. Settable from Connect IQ Settings UI or the SELECT button. |
| `last_bundle_id` | String | `""` | Persisted ID of the last successfully downloaded or received bundle. Format: 8 hex chars (CRC32 of bundle bytes, e.g. `"a3f1e7c2"`). Watch reloads from `Application.Storage["b_<id>_*"]` on app start. |

## Watch — `NavigationCalculator.mc`

| Constant | Value | Meaning |
|---|---|---|
| `OFF_ROUTE_THRESHOLD_M` | `40.0` | Distance to nearest route point above which the `OFF ROUTE` banner shows. |
| `EARTH_RADIUS_M` | `6371000.0` | Haversine formula. |

## Watch — `NavigationView.mc` (interact / zoom)

SELECT cycles: ZOOM → PAN_NS → PAN_WE → JUMP → exits TILES. Touch drag pans
directly without entering any sub-mode (see `onDrag` in `NavigationDelegate`).

| Constant / field | Value / range | Badge | Meaning |
|---|---|---|---|
| `INTERACT_ZOOM`   | `0` | `ZOOM` | SELECT cycle step 1: UP zooms in (×1.5), DOWN zooms out (÷1.5). |
| `INTERACT_PAN_NS` | `1` | `NS`   | SELECT cycle step 2: UP/DOWN pans north/south. |
| `INTERACT_PAN_WE` | `2` | `WE`   | SELECT cycle step 3: UP/DOWN pans west/east. |
| `INTERACT_JUMP`   | `3` | `JMP`  | SELECT cycle step 4: UP = center on GPS, DOWN = center on route; next SELECT exits TILES. |
| `_zoomFactor` | `0.25f – 16.0f`, default `1.0f` | | Divides `halfLat`/`halfLon` in `projectPoint()`; higher = zoomed in. Reset to `1.0f` on `applyRoute()`, `centerToGps()`, `centerToRoute()`. |
| `_panOffsetLat/Lon` | `Float`, default `0.0f` | | Degrees added to the route-center lat/lon. Updated by `panByPixels()` (touch drag) or `interactUp/Down()` (buttons). Reset by `centerToGps()` and `centerToRoute()`. |
| `_activeOsmZoom` | `12`, `13`, or `15`, default `13` | (in badge) | Active OSM tile zoom level. Set by `checkZoomSwitch()` based on `_zoomFactor` thresholds: `<0.5`→12, `0.5–3.0`→13, `≥3.0`→15. Switching triggers `switchToActiveZoom()` in `onUpdate()`. |

## Watch — `TileDecoder.mc`

| Constant | Value | Meaning |
|---|---|---|
| `BUNDLE_VERSION` | `1` | Must match `TileBundleSerializer.VERSION` and `Palette.VERSION` (Kotlin side). Bumping any of them invalidates all `bundle_*` keys in Storage. |
| `HEADER_FIXED_SIZE` | `24` | Bytes before palette starts. |
| `TILE_ENTRY_SIZE` | `21` | Bytes per tile entry. |
| `STORAGE_CHUNK` | `16 384` (16 KB) | Max bytes per Storage chunk key. |
| `MANIFEST_KEY` | `"bm"` | `App.Storage` key for the LRU bundle manifest (Array of 8-char short keys, oldest→newest). |
| `MAX_CACHED_BUNDLES` | `32` | Safety cap on cached bundles; oldest evicted when Storage is full. |
