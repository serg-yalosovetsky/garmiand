# Configuration

There are no environment variables. All knobs are compile-time constants.

## Android — `MainActivity.kt`

| Constant | Value | Meaning |
|---|---|---|
| `MAP_SERVER_PORT` | `8081` | NanoHTTPD port for the (currently unused) `MapTileServer`. |
| `MAP_WIDTH` / `MAP_HEIGHT` | `240` | Pixel size sent in `map_url` and used by the watch projection. Matches Fenix 7 screen. |
| `BBOX_PADDING_FRACTION` | `0.15` | Padding around the route bbox before picking the tile. |
| `REQUEST_GPX_FILE` | `1001` | `startActivityForResult` request code. |

## Android — `ConnectIQGarminCompanion.kt`

| Constant | Value | Meaning |
|---|---|---|
| `WATCH_APP_ID` | `71DA4029287A447BBE86B83DC1588647` | Must equal `<iq:application id="...">` in `garmin/manifest.xml`. **Change in lockstep.** |
| `SEND_TIMEOUT_MS` | `8000` | Busy-wait deadline for an `IQMessageStatus` callback. |

## Android — `NativeMapEncoder.kt`

| Parameter | Default | Meaning |
|---|---|---|
| `pointsPerChunk` | `50` | Points per `route_chunk`. ~800 bytes per chunk; safely under the ~4 KB Connect IQ message ceiling. Increase only with measurement. |

## Watch — `manifest.xml`

| Field | Value | Notes |
|---|---|---|
| `id` | `71DA4029287A447BBE86B83DC1588647` | See above. |
| `entry` | `GarmiandApp` | |
| `type` | `watch-app` | |
| products | `fenix7` | Only target supported today. |
| permissions | `Positioning`, `Communications` | No `<iq:uses-domain>` — sideloaded development is unrestricted. |
| minApiLevel | `3.3.0` | |

## Watch — `NavigationCalculator.mc`

| Constant | Value | Meaning |
|---|---|---|
| `OFF_ROUTE_THRESHOLD_M` | `40.0` | Distance to nearest route point above which the `OFF ROUTE` banner shows. |
| `EARTH_RADIUS_M` | `6371000.0` | Haversine formula. |

## Precedence / Overrides

There aren't any. If a value needs to be tunable per build, introduce a build-config field rather than parsing env vars at runtime.
