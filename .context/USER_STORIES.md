# User Stories

End-to-end flows the app supports today. If a flow isn't here, it's not in scope.

## US-1: Import a GPX route from a file

**As** a runner with a `.gpx` from OsmAnd / Komoot / Strava export,
**I want to** load it into the Android companion,
**so that** I can pick which route to push to my watch.

- Trigger: tap **Import GPX**.
- Implementation: `Intent.ACTION_OPEN_DOCUMENT` → `GpxFileImportBridge.loadFromUri`.
- Outcome: status text shows `Loaded: <name> (<n> pts)`, **Send** becomes enabled.
- Marker behavior: any `<wpt>` becomes a `Marker`; `Start` and `Finish` are auto-added at the first/last `<trkpt>`.

## US-2: Push the route to the Fenix 7

**As** a user with the watch app installed and Garmin Connect Mobile open,
**I want to** transfer the loaded route over Bluetooth,
**so that** the watch can navigate it.

- Trigger: tap **Send**.
- Implementation: `RouteSyncOrchestrator.sync(route)` → 4 messages (`sync_start`, `route_chunk*`, `markers`, `sync_finish`) via `ConnectIQGarminCompanion.send`.
- UI: progress bar shows `sent / total`; status reads `Sending X/Y...` then `Sent OK (N msgs) + map` (or `(map failed)` if `map_url` failed).
- Failure: on any non-success ack, status becomes `Failed: <reason>`. The user sees enough in the in-app log to diagnose.

## US-3: See the route as a track on a real map

**As** a user navigating outdoors,
**I want** the watch to show the route over a real-world map background,
**so that** I can orient myself relative to landmarks, not just an abstract polyline.

- Trigger: implicit, follows US-2.
- Implementation: phone picks a single OSM tile (`TileComposer.singleTileForBbox`), sends `map_url`. Watch calls `Communications.makeImageRequest`, GCM fetches via HTTPS.
- Fallback: if the image fetch fails (any non-200 response code), the watch falls back to the scale-based projection (no map background, polyline still drawn). The on-screen debug banner shows the response code.

## US-4: See current GPS position on the route

**As** a user on the move,
**I want** my position drawn on the map,
**so that** I know whether I'm tracking the route.

- Trigger: GPS lock acquired after watch app starts.
- Implementation: `Position.enableLocationEvents(LOCATION_CONTINUOUS, ...)` registered in `GarmiandApp.onStart` + 1 Hz `Timer` poll fallback (see ADR-004).
- Outcome: blue circle on the map. If `NavigationCalculator.isOffRoute(...)` returns true (distance > 40 m), a red `OFF ROUTE` banner appears.

## US-5: Pan / zoom interaction (no-map fallback only)

**As** a user without map background,
**I want** to zoom and re-center the polyline,
**so that** I can read it.

- Inputs: `UP` zooms in (scale × 0.7), `DOWN` zooms out (scale × 1.4), `SELECT` toggles auto-center on current GPS; toggling off re-fits the route to screen.
- Implementation: `NavigationDelegate` → `NavigationView.zoomIn/Out/toggleAutoCenter`.
- Note: in map mode the bbox is fixed by the tile, so zoom/pan are inert. This is intentional for MVP.

## Out of Scope (today)

- Multiple saved routes on the watch.
- Turn-by-turn voice/vibration cues.
- Route editing on the phone.
- Re-routing when off-route.
