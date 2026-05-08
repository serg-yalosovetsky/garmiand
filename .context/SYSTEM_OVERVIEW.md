# System Overview

Garmiand transfers a GPX route from an Android phone to a Garmin Fenix 7 watch
over Bluetooth (Connect IQ), and renders the route on the watch with a real
OSM map background, current GPS position, and an off-route indicator.

## Modules

- **Android companion** (`android/app/src/main/java/com/garmiand/`)
  - `ui/MainActivity.kt` — entry, GPX picker, send button, on-screen log.
  - `osmand/GpxFileImportBridge.kt` — parses `.gpx` (XmlPullParser) into `RoutePackage`.
  - `protocol/` — `SyncMessage` types, `PhoneMessageEnvelope` keys, `NativeMapEncoder`.
  - `garmin/ConnectIQGarminCompanion.kt` — Connect IQ Mobile SDK wrapper.
  - `sync/RouteSyncOrchestrator.kt` — drives the chunked send.
  - `map/` — `TileComposer` (Web Mercator math, single-tile picker), `MapTileServer` (NanoHTTPD; currently unused — see ADR), `NetworkUtil`.
  - `util/AppLog.kt` — in-app log buffer mirrored to `Log.x`; UI subscribes to it.
- **Watch app** (`garmin/source/`)
  - `GarmiandApp.mc` — `AppBase`; routes phone messages, registers GPS, kicks off `Communications.makeImageRequest` for the map.
  - `RouteData.mc` — parallel `Float[]` arrays for points and markers (no dictionaries-of-points; heap is tight).
  - `NavigationView.mc` — draws map bitmap, polyline, markers, position, banners.
  - `NavigationDelegate.mc` — input: zoom in/out, toggle auto-center.
  - `NavigationCalculator.mc` — Haversine, nearest-point, off-route check.
  - `GpsListener.mc` — kept for logging; the actual GPS subscription lives in `GarmiandApp`.

## Runtime Boundaries

- Android companion runs on the phone. It hosts the GPX import, talks to Garmin Connect Mobile (GCM) via the Connect IQ Mobile SDK.
- The watch app runs on the Fenix 7. It cannot reach the network directly — every HTTP call goes through GCM as a proxy.
- GCM is the third party in the loop and imposes the toughest constraints (see `CONNECT_IQ_NOTES.md`).

## Main Flow (happy path)

1. User picks a `.gpx` file in the Android UI.
2. `GpxFileImportBridge` parses it into `RoutePackage` (points + markers + name).
3. User taps **Send**. `RouteSyncOrchestrator` calls `NativeMapEncoder.encode(...)` and sends, in order:
   - `sync_start` → `route_chunk` (one or more, 50 pts each) → `markers` → `sync_finish`.
4. After ack of `sync_finish`, `MainActivity.sendMapUrl(...)` picks a single OSM tile (`TileComposer.singleTileForBbox`) that contains the whole padded route, and sends `map_url` with the tile bbox.
5. The watch receives `map_url`, calls `Communications.makeImageRequest`, GCM fetches the PNG, returns a `BitmapResource`.
6. `NavigationView` draws bitmap → red polyline → yellow markers → blue position → optional `OFF ROUTE` banner.

## What There Is No

- No backend service, no database, no auth. The phone is the source of truth for routes.
- No `MapTileServer` in the active path — kept under `map/` for future work, but currently bypassed in favor of fetching directly from `tile.openstreetmap.org` (see `ADR_LOG.md`).
