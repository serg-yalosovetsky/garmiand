# System Overview

Garmiand transfers a GPX route from an Android phone to a Garmin Fenix 7 watch
over Bluetooth (Connect IQ), then renders the route on the watch over a map
background, with current GPS position and an off-route indicator.

The map rendering has three modes — Garmin's pre-installed TopoActive vector
map (default), a quantized custom raster bundle (opt-in), or none. The
quantized bundle gets to the watch via either HTTPS (through our own backend)
or BLE (chunked, when phone is offline). See [MAP_RENDERING.md](MAP_RENDERING.md)
for the full pipeline.

## Modules

- **Android companion** (`android/app/src/main/java/com/garmiand/`)
  - `ui/MainActivity.kt` — entry, GPX picker, **Cache map for offline** toggle, send button, in-app log.
  - `osmand/GpxFileImportBridge.kt` — parses `.gpx` (XmlPullParser) into `RoutePackage`.
  - `protocol/` — `SyncMessage` types (`SyncStart`, `RouteChunk`, `Markers`, `SyncFinish`, `TileSession`, `TileChunk`), `PhoneMessageEnvelope` keys, `NativeMapEncoder` (route → messages) + `SyncMessageSerializer` (typed → wire dict).
  - `garmin/ConnectIQGarminCompanion.kt` — Connect IQ Mobile SDK wrapper.
  - `sync/`
    - `RouteSyncOrchestrator.kt` — drives the chunked send.
    - `MapBundleUploader.kt` — POSTs a quantized bundle to the backend, returns `{bundleId, downloadUrl}`.
    - `MapBundleBleSender.kt` — chunks a bundle into ≤3 KB BLE messages.
  - `map/`
    - `Palette.kt` — fixed 64-color palette (4×4×4 RGB cube) shared with the watch.
    - `TileQuantizer.kt` — fetches OSM tiles, quantizes to 64-color column-major bytes.
    - `TileBundleSerializer.kt` — emits the `GMND` binary envelope.
  - `util/AppLog.kt` — in-app log buffer mirrored to `Log.x`; UI subscribes to it.
- **Watch app** (`garmin/source/`)
  - `GarmiandApp.mc` — `AppBase`; routes phone messages (`sync_*`, `tile_session`, `tile_chunk`), registers GPS, drives `Communications.makeWebRequest` for HTTPS bundle fetch.
  - `RouteData.mc` — parallel `Float[]` arrays for points and markers (no dictionaries-of-points; heap is tight).
  - `NavigationView.mc` — extends `WatchUi.View`. Owns the three map-mode rendering paths and decoded `BufferedBitmap` cache.
  - `NavigationDelegate.mc` — input: SELECT cycles map mode (NATIVE → TILES → NONE).
  - `NavigationCalculator.mc` — Haversine, nearest-point, off-route check.
  - `TileDecoder.mc` — parses the `GMND` envelope, decodes column-major palette indices into `BufferedBitmap`s.
  - `BleChunkAssembler.mc` — reassembles `tile_chunk` messages into a bundle blob and persists to `Application.Storage`.
- **Backend** (`server/`)
  - `src/server.js` — Express + raw-body `POST /sessions`, base64 `GET /sessions/:id`, hourly retention.
  - `Dockerfile` — Alpine, ~50 MB image. See [BACKEND.md](BACKEND.md).

## Runtime boundaries

- Android companion runs on the phone. It hosts GPX import, talks to Garmin Connect Mobile (GCM) via the Connect IQ Mobile SDK, and (optionally) talks HTTPS to our backend.
- The watch app runs on the Fenix 7. It cannot reach the network directly — every HTTP call goes through GCM as a proxy. GCM does not proxy phone-local IPs (this is why we run our own internet-facing backend rather than serving locally — see ADR-006).
- The backend is a thin broker. Phone uploads, watch downloads. Server holds blobs for `RETENTION_DAYS` (default 7).

## Main flows

### Route sync (happy path, all modes)
1. User picks a `.gpx` file in the Android UI.
2. `GpxFileImportBridge` parses it into `RoutePackage`.
3. User taps **Send**. `RouteSyncOrchestrator` calls `NativeMapEncoder.encode(...)` and sends, in order: `sync_start` → `route_chunk` (one or more, 50 pts each) → `markers` → `sync_finish`.
4. Watch's `GarmiandApp.onPhoneMessage` accumulates the route and on `sync_finish` flips `RouteData.isComplete = true` and frames the bbox via `NavigationView.applyRoute`.

### Bundle delivery — HTTPS path (online)
5. With **Cache map for offline** toggled on, `MainActivity.sendMapBundle` runs after a successful sync.
6. `TileQuantizer` downloads OSM tiles for the route bbox and quantizes them column-major against `Palette`.
7. `TileBundleSerializer` emits the `GMND` binary blob.
8. `MapBundleUploader` POSTs the blob to `${BACKEND_URL}/sessions`. Server returns `{bundleId, downloadUrl}`.
9. Phone sends a `tile_session` BLE message with `bundle_id` + `download_url`.
10. Watch's `handleTileSession` calls `Communications.makeWebRequest` (server returns base64 plain text), decodes via `StringUtil.convertEncodedString`, persists with `TileDecoder.persist`, and `NavigationView.setBundleId` re-decodes tiles into `BufferedBitmap`s.

### Bundle delivery — BLE path (offline fallback)
5'. If phone has no internet (`isNetworkOnline()` is false), `MapBundleBleSender` chunks the bundle into ≤3 KB pieces and sends each as a `tile_chunk` message.
6'. Watch's `BleChunkAssembler` indexes by `i`, assembles when all chunks arrive, persists, and triggers tile decode.

## What there is no

- No always-on backend dependency. Empty `BACKEND_URL` falls back to BLE — slow but functional.
- No JSON parser on the watch (still). Bundle format is binary; phone messages are native dictionaries.
- No per-user auth on the backend. Single shared `BACKEND_TOKEN`. UUIDv4 session IDs are unguessable in any practical sense.
