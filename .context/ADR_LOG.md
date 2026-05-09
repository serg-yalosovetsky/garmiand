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

## ADR-008: MapView is the default; custom tiles are opt-in

**Decision.** `NavigationView extends WatchUi.MapView`. The default mode
renders Garmin's pre-installed TopoActive map natively (zero data transfer).
Users can switch to "Custom Tiles" mode (the bundle from ADR-006) when their
region has no TopoActive coverage or they want OSM detail. A "None" mode
(empty background, just polyline) is also available.

**Why.** TopoActive is offline-by-default for the Fenix 7's regional map. For
most users this means zero setup. The hybrid bundle path exists for the
travel-outside-Europe / want-a-different-map cases, not as the primary UX.

**Implication.** `Map` permission required in `manifest.xml`. The
`MAP_MODE_BROWSE` setting gives users native pan/zoom in MapView mode. In
TILES and NONE modes, the route polyline is drawn manually via
`latLonToScreenPoint` so it tracks whatever viewport the user dialed in via
MapView.
