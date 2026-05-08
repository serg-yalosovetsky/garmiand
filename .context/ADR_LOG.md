# Architecture Decisions

Decisions here are load-bearing. Don't reverse them without the same reasoning that produced them.

## ADR-001: Native `Dictionary` protocol, not JSON+Base64

**Decision.** Phone-to-watch messages travel as native `Map<String, Any>` via `IQApp.sendMessage()`. The watch reads them as `Lang.Dictionary`.

**Why.** Monkey C has no built-in JSON parser. An earlier `JsonRouteChunkEncoder` packed points into a JSON string and Base64; the watch then needed a JSON parser, which on Fenix 7's heap budget is not viable. Connect IQ already serializes Kotlin `Map<String, Any>` into native dictionaries on the watch — we use that and skip parsing entirely.

**Implication.** Schema lives in [PhoneMessageEnvelope.kt](../android/app/src/main/java/com/garmiand/protocol/PhoneMessageEnvelope.kt) and matching string-key reads in `GarmiandApp.onPhoneMessage`. Both must change together.

## ADR-002: Parallel float arrays for route storage on the watch

**Decision.** `RouteData` stores `lats: Float[]`, `lons: Float[]`, `markerLats: Float[]`, etc. — never `Array<Dictionary>`.

**Why.** Heap on Fenix 7 is ~256 KB. Dictionaries carry per-entry overhead that explodes at 500+ points. Parallel `Float[]` arrays are flat and predictable.

**Implication.** Marker fields are also flat arrays (`markerIds[]`, `markerLats[]`, ...). Index alignment across these arrays is invariant — `setMarkers(...)` must keep them in sync.

## ADR-003: Map fetch is a public OSM tile, not the local `MapTileServer`

**Decision.** Watch fetches the map from `https://tile.openstreetmap.org/{z}/{x}/{y}.png`. The phone picks a single tile that contains the padded route bbox via `TileComposer.singleTileForBbox(...)`. The local `MapTileServer` (NanoHTTPD on `0.0.0.0:8081`) is kept in the codebase but not in the active path.

**Why.** GCM does not route HTTP requests from the watch to phone-local addresses — neither `127.0.0.1` nor LAN IP (`192.168.x.x`). Tested with both: `MapTileServer` never received a request even though `map_url` was acked. Public HTTPS works (verified with a deliberate-404 staticmap test). A direct OSM tile URL is the simplest reliable path.

**Implication.** Map detail is bounded by what fits in one 256×256 tile. For large routes the chosen zoom drops and detail suffers — acceptable for MVP. If we need finer maps later, options are: a public tunnel to `MapTileServer` (ngrok-style), or a third-party static-map service with an API key.

## ADR-004: Position registration lives in `AppBase`, not `GpsListener`

**Decision.** `GarmiandApp.onStart` calls `Position.enableLocationEvents(LOCATION_CONTINUOUS, ...)` and starts a `Timer.Timer` that polls `Position.getInfo()` every second.

**Why.** In the Connect IQ simulator the position-event callback registered from a non-`AppBase` class never fires. Registering at the `AppBase` level + the timer poll fallback worked on both simulator and the physical device.

**Implication.** `GpsListener.mc` is kept for logging only — it is not the GPS source. Don't move the registration back into it.

## ADR-005: Phone-side observability is the in-app log

**Decision.** Use `util/AppLog.kt` for all observable events on the Android side. The UI subscribes; `Log.x` is also called for `adb logcat`. The watch reflects critical state (map response code, last URL tail) onto the screen in a small banner.

**Why.** On physical Garmin hardware there is no `System.println` capture for sideloaded apps; `CIQ_LOG.YML` only fires on unhandled exceptions. The combination of phone in-app log + on-screen watch banner gives full visibility without any cable.
