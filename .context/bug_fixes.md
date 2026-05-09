# Bug Fixes / Regression-Sensitive Areas

Recurring sources of bugs and the rules that keep them away.

## "Watch app not found"

`ConnectIQGarminCompanion.discoverDevice` returns false. Order of suspicion:

1. **`.prg` not actually on the watch** — the most common cause. Reinstall via sideload. After copying, force-stop GCM and reopen.
2. **`WATCH_APP_ID` ↔ `manifest.xml` id mismatch.** Both must be the same UUID. They are tied at compile time — if you change one, change both.
3. **`knownDevices.firstOrNull()` picked a stale device.** We now prefer `getConnectedDevices()` first; do not regress that — see `discoverDevice`.
4. **Watch isn't `CONNECTED` in GCM** — re-pair / restart Bluetooth.

## Map doesn't appear in TILES mode

Order of suspicion:

1. **Don't add a `Map` permission to the manifest.** It is invalid in SDK 9.1.0
   and breaks the build (`Invalid permission provided: Map`). MapView works
   without it.
2. **No bundle in Storage.** Watch shows `TILES: no bundle`. Either the
   "Cache map for offline" switch wasn't on at sync time, or the transfer
   failed. Re-sync.
3. **Bundle parse failed.** Watch shows `TILES: header parse failed`. The
   palette or version mismatched. Check `Palette.VERSION` in Kotlin matches
   `BUNDLE_VERSION` in `TileDecoder.mc`.
4. **Tile decode failed.** Watch shows `TILES: decode failed`. Usually
   graphics memory pool exceeded — too many active `BufferedBitmap`s. Try
   switching to NATIVE mode (frees the cache) and back.
5. **HTTPS path silent.** Phone shows `(map failed)`. Either `BACKEND_URL`
   is empty in BuildConfig, the backend is down, or the Bearer token is
   wrong. Falls back to BLE if `isNetworkOnline()` is false.

## Application.Storage full

`StorageFullException` from `App.Storage.setValue`. We currently store at most
one bundle (`bundle_<id>`) and overwrite old `last_bundle_id`. If a stale key
sticks around (e.g. from a crashed BLE sync), the assembler should
`deleteValue` it. If it keeps happening, dump the storage keys via the
simulator's `Settings → Edit Storage` panel and prune manually.

## Tile chunks arrive out of order

`BleChunkAssembler.accept` indexes by `i`, so order doesn't matter — but if
chunks for two different `bundle_id`s interleave (rare; would only happen if
the user spams Send), the assembler resets to the new bundle and drops
partial state. Confirmed safe by the bundle-id check.

## "send tile_chunk failed: Send timeout" but ack arrives shortly after

This bit us once already on Fenix 7: a 3 KB chunk acked in ~8.2 s, the
busy-wait in `ConnectIQGarminCompanion.send` gave up at 8 s, and the sender
bailed even though the chunk was actually delivered. Two responses:

- `SEND_TIMEOUT_MS` is now 30 s (was 8 s) — generous enough for any chunk
  size we send.
- `MapBundleBleSender.DEFAULT_CHUNK_SIZE` is 1500 (was 3000) — smaller chunks
  ack in ~4 s, tighter progress feedback, no risk of brushing the timeout.

If you ever see the timeout again, check throughput in the log and consider
dropping the chunk size further (down to ~800 B). Don't shorten the timeout
to "fail fast" — Garmin BLE genuinely takes that long.

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

## "Watch shows polyline but no tiles even though I sent the bundle"

Check `last_bundle_id` Property on the watch (Connect IQ Settings UI). If it's
set but TILES mode shows the empty-bundle text, the blob is missing from
Storage — most likely BLE chunk reassembly bailed mid-way. Resend with the
"Cache map for offline" switch on, watching the log for `BLE chunk N/N` to
make sure all chunks acked.
