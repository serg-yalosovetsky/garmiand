# Bug Fixes / Regression-Sensitive Areas

Recurring sources of bugs and the rules that keep them away.

## "Watch app not found"

`ConnectIQGarminCompanion.discoverDevice` returns false. Order of suspicion:

1. **`.prg` not actually on the watch** — the most common cause. Reinstall via sideload. After copying, force-stop GCM and reopen.
2. **`WATCH_APP_ID` ↔ `manifest.xml` id mismatch.** Both must be the same UUID. They are tied at compile time — if you change one, change both.
3. **`knownDevices.firstOrNull()` picked a stale device.** We now prefer `getConnectedDevices()` first; do not regress that — see `discoverDevice`.
4. **Watch isn't `CONNECTED` in GCM** — re-pair / restart Bluetooth.

## Map doesn't appear on the watch

The route polyline shows but no map background. Diagnose by reading the yellow bottom-banner on the watch:

- No banner at all → the `map_url` message never reached the watch (check `ack map_url status` in the Android log).
- `requesting…` but never updates → `Communications.makeImageRequest` is hanging (rare; usually a GCM hiccup, restart it).
- `code=200 d=0` → response was OK but the image couldn't be decoded; usually a content-type mismatch.
- `code=200 d=1` but no map drawn → the bug is on the rendering side; check `_mapBitmap` lifetime in `GarmiandApp`.
- `code=403` / `404` / `-101` etc. → see the table in `CONNECT_IQ_NOTES.md`.

**Don't** "fix" this by switching to `127.0.0.1` or LAN IP. We've tested both — GCM does not proxy them. ADR-003 is non-negotiable until a public tunnel option exists.

## Markers missing after sync

`route_chunk` and the polyline draw, but markers don't show. Almost always caused by forgetting to call `WatchUi.requestUpdate()` inside the `markers` branch of `onPhoneMessage`. The handler must call it on every successful state mutation.

## GPS callback never fires

In the simulator, position events from a non-`AppBase` listener never fire. We have:
- `Position.enableLocationEvents(LOCATION_CONTINUOUS, ...)` registered at `AppBase` level.
- A `Timer.Timer` polling `Position.getInfo()` every 1000 ms.

Both are required. If you remove either, GPS will silently break in the sim. See ADR-004.

## Off-route status flicker

`NavigationCalculator.isOffRoute` is a hard threshold (`OFF_ROUTE_THRESHOLD_M = 40 m`). Flicker at the boundary is expected. If we ever care, hysteresis (separate enter/exit thresholds) is the fix — don't change the single constant in isolation.

## Type-related Monkey C warnings

Strict typing is the rule. If you see `Invalid '$.Toybox.Lang.Method(...)' passed as parameter`, the callback declaration is missing types. Annotate the *callback's* parameters and return type, not just the call site.

## Heap overrun on long routes (Fenix 7)

If `RouteData` ever gets converted to `Array<Dictionary>`, expect OOM around 500 points. See ADR-002. If the user needs longer routes, prefer point thinning in `NativeMapEncoder` over richer per-point storage.

## `route_full` debug message has surprising consequences

`GarmiandApp` accepts a `route_full` kind that bundles the whole sync into one message — for the Connect IQ simulator's `Phone → Send Message` tester. The Android companion never sends it. If you build production code that depends on `route_full`, you've taken a wrong turn — use the chunked path.

## Cleartext HTTP

`AndroidManifest.xml` sets `usesCleartextTraffic="true"` so `MapTileServer` can be hit over plain HTTP. This isn't currently used (ADR-003), but the flag has to stay if we ever revive the local server. Don't remove it as a "cleanup."
