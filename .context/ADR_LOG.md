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

## ADR-003: Map fetch is a public OSM tile, not the local `MapTileServer` *(superseded by ADR-006)*

**Decision (historical).** Watch fetched the map from `https://tile.openstreetmap.org/{z}/{x}/{y}.png`. The phone picked a single tile that contained the padded route bbox via `TileComposer.singleTileForBbox(...)`.

**Why this was wrong for offline.** Required live internet on the phone at navigation time, and a single 256×256 tile gave no flexibility for area selection. GCM still does not route HTTP to phone-local addresses (the original `127.0.0.1` problem), but the fix is no longer "use a public tile URL" — it's the hybrid scheme in ADR-006.

**Status.** Superseded. `MapTileServer.kt`, `TileComposer.kt`, `NetworkUtil.kt`, and the `KIND_MAP_URL` envelope are gone. `usesCleartextTraffic` is removed from the manifest.

## ADR-004: Position registration lives in `AppBase`, not `GpsListener`

**Decision.** `GarmiandApp.onStart` calls `Position.enableLocationEvents(LOCATION_CONTINUOUS, ...)` and starts a `Timer.Timer` that polls `Position.getInfo()` every second.

**Why.** In the Connect IQ simulator the position-event callback registered from a non-`AppBase` class never fires. Registering at the `AppBase` level + the timer poll fallback worked on both simulator and the physical device.

**Implication.** `GpsListener.mc` is kept for logging only — it is not the GPS source. Don't move the registration back into it.

## ADR-005: Phone-side observability is the in-app log

**Decision.** Use `util/AppLog.kt` for all observable events on the Android side. The UI subscribes; `Log.x` is also called for `adb logcat`. The watch reflects critical state (map response code, last URL tail) onto the screen in a small banner.

**Why.** On physical Garmin hardware there is no `System.println` capture for sideloaded apps; `CIQ_LOG.YML` only fires on unhandled exceptions. The combination of phone in-app log + on-screen watch banner gives full visibility without any cable.

## ADR-006: Hybrid tile delivery (HTTPS via cloud broker + BLE direct)

**Decision.** Map background is delivered to the watch as a quantized binary
bundle (the `GMND` envelope, see [MAP_RENDERING.md](MAP_RENDERING.md)) over
**two interchangeable transports**, sharing the same on-wire format:

1. **HTTPS path (preferred when phone has internet).** Phone uploads the bundle
   to our own backend (`POST /sessions`, see [BACKEND.md](BACKEND.md)). Phone
   announces the resulting `bundleId` + `downloadUrl` via a `tile_session` BLE
   message. Watch fetches the URL with `Communications.makeWebRequest()`
   (response is base64 plain text — Connect IQ does not give us raw bytes).
2. **BLE direct path (offline fallback).** Phone splits the bundle into
   ~3 KB chunks and sends them as `tile_chunk` messages with sequence
   numbers. Watch reassembles by index in `BleChunkAssembler`.

In both paths the watch persists the assembled blob to
`Application.Storage["bundle_<id>"]` and renders from there.

**Why.** Pure HTTPS leaves field trips dead when phone goes offline. Pure BLE
forces every user to wait minutes for a transfer they could've done at home in
seconds. Two paths cost twice the protocol code, but only one wire format, so
the watch decoder is shared.

**Implication.** A new dependency: our own backend (`server/`). Without it,
the HTTPS path silently falls back to BLE — which keeps everything working but
slower. `BACKEND_URL` empty in BuildConfig means BLE-only.

## ADR-007: Cloud broker is our own Node.js server, not S3 / public CDN

**Decision.** The HTTPS path goes through `server/` — a tiny Node.js + Express
service. POST returns `{sessionId, downloadUrl}`; GET returns the bundle as
base64 text/plain.

**Why.** S3 presigned URLs would have worked, but tied us to AWS conventions
and made auth/retention awkward. GitHub Releases would have made every route
publicly indexable. A 200-line Express server gives us full control of auth
(shared bearer token in v1), retention (TTL on disk), and the response format
(base64 text — required because Connect IQ's `makeWebRequest` cannot ingest
raw octet streams).

**Implication.** We carry ops cost: deploy, monitor, TLS cert. Stage 0 of
production is "run it on Fly.io for €0/mo, write the URL into
`gradle.properties`." Per-user auth is deferred — until then, anyone with the
shared token can upload, and anyone with a `sessionId` (UUIDv4, unguessable)
can read.

## ADR-009: Incremental column-by-column tile decode

**Decision.** Tile pixel decoding is spread across multiple `onUpdate()` frames:
8 columns per frame via `TileDecoder.fillTileColumns()`. The `BufferedBitmap`
Dc is held open between frames in `NavigationView._currentTileDc`. Heavy work
is never done inside HTTP/BLE callbacks.

**Why.** Three alternatives all failed:
1. *All pixels at once in `onUpdate`* — a single 128×128 tile trips the
   watchdog (16 384 loop iterations is too slow in the CIQ simulator).
2. *`BufferedBitmap.getBuffer()` for direct index writes* — the method does
   not exist in SDK 9.1.0 / fenix7; `monkeyc` rejects it at compile time.
3. *All pixels in HTTP/BLE callback* — callbacks have a shorter watchdog
   budget than `onUpdate`; crashes immediately.

Column-granularity (8 cols = ~1 024 inner-loop iterations) is well within
budget and gives continuous progress: partial tiles become visible frame by
frame.

**Implication.** `NavigationView` carries incremental decode state:
`_pendingBlob`, `_pendingEntries`, `_pendingTileIndex`, `_pendingColIndex`,
`_currentTileBmp`, `_currentTileDc`. `clearDecodedTiles()` must reset all of
them. `ensureBundleLoaded()` must be called before the `_route.isComplete`
guard in `onUpdate()`.

## ADR-008: Plain `WatchUi.View` with manual projection; MapView abandoned

**Decision.** `NavigationView extends WatchUi.View` (not `WatchUi.MapView`).
All three background modes (NATIVE/TILES/NONE) draw a plain black background
and render the route polyline, waypoints, and GPS position via `projectPoint`
— a linear lon/lat → fraction → pixel conversion using a viewport tracked
in `_viewLat0/1, _viewLon0/1`.

**Why MapView was removed.** An earlier version extended `WatchUi.MapView`
with TopoActive rendering as the NATIVE default. It was dropped because
`MapView.onUpdate()` crashed in the simulator (unrecoverable), which blocked
development and testing. Without a reliable dev path the MapView variant was
not worth carrying. All modes now use the same manual overlay approach.

**Implication.** There is no background map in NATIVE mode — it's a black
screen with the polyline drawn on top, same as TILES/NONE. No Map permission
is required (and `<iq:uses-permission id="Map"/>` would break the build
anyway). The viewport is computed once in `applyRoute()` from route bbox
+ 15% padding, but the user can pan and zoom interactively in TILES mode via
the SELECT → UP/DOWN cycle (see ADR-011). If native Garmin TopoActive
rendering is needed in the future, MapView would need to be re-evaluated on
hardware (not the simulator).

## ADR-011: Web Mercator tile positioning with `drawScaledBitmap`

**Decision.** Each decoded `BufferedBitmap` is rendered via
`dc.drawScaledBitmap(sx, sy, sw, sh, bmp)` where `(sx, sy, sw, sh)` is the
tile's geographic bounding box projected through `projectPoint()`, computed
at render time from the tile's `(zoom, tileX, tileY)` stored in `DecodedTile`.

**Why not "draw at native pixel size."** The previous approach anchored the
tile grid by projecting the bundle's NW corner to a screen offset and drawing
each tile at a fixed 128-pixel size. This only works when the viewport and
the tile grid are the same size. In practice at zoom 13, one tile spans
~0.022°lat × 0.044°lon while a typical route viewport is ~0.01°lat wide.
Projecting the bundle NW corner yields y ≈ −253 px — the entire tile grid
is above the screen. "Centred at native pixel size" formulas failed for the
same reason: geographic and pixel extents only match when the quantizer is
told to produce exactly the right zoom level for the viewport, which is
fragile.

**Why `drawScaledBitmap` is safe.** `Graphics.Dc.drawScaledBitmap(x, y, w, h, bmp)`
is available in SDK 9.1.0 / fenix7. Per-frame cost is negligible (bitmap
scaling happens in the graphics engine, not the VM). Tiles that project
off-screen are skipped (`tileScreenRect` returns null).

**The Web Mercator inverse math.** `tileYToLat(ty, n)` implements
`atan(sinh(π*(1 - 2*ty/n)))`. `sinh(x)` is computed as
`(Math.pow(Math.E, x) - 1/Math.pow(Math.E, x)) * 0.5` because `Math.exp`
does not exist in SDK 9.1.0. Longitude is trivial: `tx/n*360 - 180`.

**Implication.** `DecodedTile` stores `(zoom, tileX, tileY)` instead of
pre-computed pixel coordinates. `drawCustomTiles()` calls `tileScreenRect()`
per tile per frame (lightweight: two `projectPoint()` calls each).
No bundle-level pixel-grid state (`_pendingMinX/Y`, `_bundlePixelW/H`) is
needed.

## ADR-010: Deferred BLE chunk processing + resumable transfer

**Decision.** All BLE chunk processing is deferred from the `onPhoneMessage`
callback to `onUpdate()`. The `onPhoneMessage` handler only queues the chunk
dict into `_pendingTileChunk`; `processPendingTileChunk()` in `onUpdate()` does
the actual `BleChunkAssembler.accept()` byte-copy. Each received chunk is
immediately persisted to `App.Storage` (`ble_wip_c_N`), so the assembler can
be restored after an app restart. The phone probes the watch before each
transfer via `ble_bundle_start` → `ble_wip_report` to skip already-received
chunks. The phone also pauses 10 s every 2 minutes of continuous sending.

**Why.** Three forces converged:
1. *Watchdog in BLE callback.* Even a 3 KB byte-copy (~12K bytecodes) in
   `onPhoneMessage` can trip the watchdog. Deferring to `onUpdate()` gives the
   full frame budget.
2. *Transfer reliability.* On a 65 KB bundle at 300 ms/chunk the transfer takes
   ~5 minutes. The user may close the watch app. Without WIP persistence, the
   whole transfer restarts; with WIP, the phone queries the watch and skips
   already-received chunks.
3. *Phone pacing.* Even with watchdog-safe chunk processing on the watch,
   sending continuously for >2 minutes starves the watch's VM. A safety pause
   on the phone side avoids this.

**Implication.** Order in `onUpdate()` is load-bearing: `processPendingPersist()`
must run before `processPendingTileChunk()`. If reversed, the last chunk's
byte-copy and its Storage persist land in the same frame, approaching the watchdog
limit. Any future work in `onPhoneMessage` should be constrained to queueing only.
