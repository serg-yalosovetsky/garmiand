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
5. **Tiles decoded but invisible.** Badge says "[NS] ok" but screen background
   is black. Caused by wrong tile positioning — see "Tiles decode successfully
   but are invisible (off-screen projection)" below.
6. **HTTPS path silent.** Phone shows `(map failed)`. Either `BACKEND_URL`
   is empty in BuildConfig, the backend is down, or the Bearer token is
   wrong. Falls back to BLE if `isNetworkOnline()` is false.

## Application.Storage per-value OOM crash

`App.Storage.setValue` with a `ByteArray` larger than ~32 KB kills the app
with an unhandled OOM — **not** a catchable `StorageFullException`. The crash
stack points into `setValue` with no useful context.

Fix: `TileDecoder.persist` splits the blob into 16 KB chunks stored under
separate keys (`b_<id>_0`, `b_<id>_1`, …). Never call `setValue` with more
than 16 KB at a time. Don't confuse this with the total-storage limit (~128 KB
per app) — that's a separate, catchable `StorageFullException`.

## Application.Storage total full

`StorageFullException` (catchable) from `App.Storage.setValue`. We currently
store at most one bundle (five 16 KB chunk keys + two metadata keys). If a
stale bundle sticks around from a crashed sync, delete it via the simulator's
`Settings → Edit Storage` or call `TileDecoder.deleteBundle(oldId)` explicitly
before persisting a new one.

## Tile chunks arrive out of order

`BleChunkAssembler.accept` indexes by `i`, so order doesn't matter — but if
chunks for two different `bundle_id`s interleave (rare; would only happen if
the user spams Send), the assembler resets to the new bundle and drops
partial state. Confirmed safe by the bundle-id check.

## "send tile_chunk failed: Send timeout" but ack arrives shortly after

This bit us once already on Fenix 7: a chunk acked in ~8.2 s, the
busy-wait in `ConnectIQGarminCompanion.send` gave up at 8 s, and the sender
bailed even though the chunk was actually delivered. Two responses:

- `SEND_TIMEOUT_MS` is now 30 s (was 8 s) — generous enough for any chunk
  size we send.
- `MapBundleBleSender.DEFAULT_CHUNK_SIZE` is 3072 (3 KB), down from 12 KB.
  Smaller chunks ack faster, provide per-chunk progress feedback, and stay
  well inside the Garmin per-message limit (~4 KB).
- Inter-chunk delay is 300 ms (was 150 ms) to give the BLE queue room.

If you ever see the timeout again, check throughput in the log and consider
dropping the chunk size further (down to ~800 B). Don't shorten the timeout
to "fail fast" — Garmin BLE genuinely takes that long.

## BleChunkAssembler watchdog crash — deferred to onUpdate

**Symptom.** Watch crashes on arrival of a BLE `tile_chunk`, with `CIQ_LOG.YML` showing:

```
Error: 'Watchdog Tripped Error - Code Executed Too Long'
Stack: BleChunkAssembler.mc:95  accept()
       GarmiandApp.mc:381       handleTileChunk()
       GarmiandApp.mc:195       onPhoneMessage()
```

**Root cause.** `onPhoneMessage` is a BLE event callback with a shorter
watchdog budget than `onUpdate`. Any meaningful work inside it — even copying
3 KB of bytes — can trip the watchdog.

**Fix.** `onPhoneMessage` only queues the incoming dict into `_pendingTileChunk`.
`processPendingTileChunk()`, called from the top of `onUpdate()`, does the
actual work (calls `BleChunkAssembler.accept()` which does the byte-copy). The
`onUpdate()` budget is the full frame budget. See `GarmiandApp.processPendingTileChunk()`.

**Critical ordering.** In `NavigationView.onUpdate()`, `processPendingPersist()`
must run **before** `processPendingTileChunk()`. This ensures that the last
chunk's blob-copy and its subsequent persist never land in the same frame.
Reversing the order re-introduces a watchdog on the final chunk.

**Invariant.** The `tb` field in `tile_chunk` must be the uncompressed bundle
size in bytes. `MapBundleBleSender` sets `totalBytes = bundle.size` in every
chunk. On the first chunk, the assembler pre-allocates `_blob = new [tb]b`
and writes each chunk at `offset = i × chunkSize`. If `tb` is absent, it
falls back to dynamic `addAll` growth.

## BLE chunk stall detection

If the phone stops sending mid-transfer (e.g. BLE drop, user navigates away),
the watch has a pre-allocated `_blob` buffer pinned in RAM with no way to
know the transfer is dead. A 10-second one-shot `Timer` (`_bleStallTimer` in
`GarmiandApp`) is armed after each chunk and re-armed on each subsequent
chunk. If no chunk arrives within 10 s:

- `onBleStallTimeout()` logs `BLE STALL N/M missing=[...]` with which
  chunk indices were not received.
- `_bleChunkAssembler` is set to `null`, freeing the pre-allocated buffer.
- The assembler is recreated fresh if the phone retries (or restored from WIP
  Storage if the app is restarted).

The stall timer is disarmed immediately when the final chunk completes.

**WIP persistence survives app restart.** Each received chunk is immediately
written to `App.Storage` under `ble_wip_c_N`. On `onStart()`, if `ble_wip_id`
exists in Storage, the assembler is restored from those keys — the phone's
`ble_bundle_start` handshake then reads back which chunk indices are already on
the watch, and the phone skips them.

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

## makeWebRequest -402 on large bundles

Error code `-402` (`NETWORK_RESPONSE_OUT_OF_MEMORY`) fires when the response
body exceeds the Connect IQ TEXT_PLAIN buffer (~12–16 KB). A 65 KB bundle
base64-encoded is ~87 KB — well over the limit.

Fix: use the server's `/chunk` endpoint and download in 10 KB slices. The
app code is in `GarmiandApp.handleTileSession` (starts the first request)
and `onBundleChunkResponse` (loops until `_dlOffset >= _dlTotal`). Never try
to fetch the full bundle in one `makeWebRequest` call.

## Watchdog trips in HTTP callback or onPhoneMessage

Connect IQ watchdogs fire faster in HTTP/BLE callbacks than in `onUpdate`.
Calling `TileDecoder.load()` (even the fast `addAll` version) from inside
`onBundleChunkResponse` causes a watchdog crash with stack pointing into
`TileDecoder.mc:load()`.

Rule: **no heavy work in event callbacks.** `setBundleId()` must only store
the ID and reset `_bundleLoadAttempted = false`. The actual `loadBundle()` call
happens in `ensureBundleLoaded()` at the top of `onUpdate()` — and this call
must happen **before** the `_route.isComplete` guard, or the waiting screen
will block it indefinitely.

## Watchdog trips during tile decode

Even with RLE optimization, a single 128×128 tile (16 384 inner-loop iterations)
trips the watchdog in `onUpdate`. Decoding all 4 tiles at once is fatal.

Fix: process **8 columns per `onUpdate` frame** via `TileDecoder.fillTileColumns`.
The `BufferedBitmap` Dc is retained between frames in `_currentTileDc`. This
gives 64 frames to decode 4 tiles, each frame doing ≤1 024 iterations.

## `new [0]b` vs `[] as Lang.ByteArray` crash

`[] as Lang.ByteArray` is accepted by `monkeyc` but at runtime it's a regular
`Lang.Array`, not a `ByteArray`. Calling `.addAll()` on it throws
`UnexpectedTypeException: Expected Array, given ByteArray`. Always use `new [0]b`
for an empty growable ByteArray, or `new [N]b` for fixed size.

## `getBuffer()` compile error on fenix7

`Graphics.BufferedBitmapType.getBuffer()` does not exist in SDK 9.1.0 / fenix7.
`monkeyc` errors with "Undefined symbol ':getBuffer' detected". Remove any
reference to it; use the Dc API instead.

## "Watch shows polyline but no tiles even though I sent the bundle"

Check `last_bundle_id` Property on the watch (Connect IQ Settings UI). If it's
set but TILES mode shows the empty-bundle text, the blob is missing from
Storage — most likely BLE chunk reassembly bailed mid-way. Resend with the
"Cache map for offline" switch on, watching the log for `BLE chunk N/N` to
make sure all chunks acked.

## `instanceof Lang.Numeric` compile error: "Undefined symbol ':Numeric'"

**Symptom.** `monkeyc` fails with:

```
BleChunkAssembler.mc:59,8: Undefined symbol ':Numeric' detected
```

**Root cause.** `Lang.Numeric` is an abstract interface in the Connect IQ type hierarchy
and cannot be used as an operand of `instanceof`. The compiler only accepts concrete
classes (`Lang.Number`, `Lang.Float`, `Lang.Double`, `Lang.Long`) in `instanceof`
expressions.

**Fix.** Replace every `instanceof Lang.Numeric` / `as Lang.Numeric` with the
appropriate concrete type:
- Integer fields (indices, counts, flags) → `Lang.Number`
- Coordinate fields (lat/lon) received from Android → `Lang.Float`
  (Android `Double` arrives on the watch as a CIQ `Float`)

Files affected: `BleChunkAssembler.mc`, `GarmiandApp.mc`, `RouteData.mc`.

**Rule.** Never use `Lang.Numeric`, `Lang.Comparable`, or any other abstract CIQ
interface in an `instanceof` or `as` cast — they compile on some SDK versions and
silently fail on others. Always cast to the concrete leaf type.

## `while (true)` compile error: "Not all paths return a value"

`monkeyc` does not recognize `while (true)` as an infinite loop. A function
containing only a `while (true) { … return …; }` body will fail with:

```
Not all paths return a value.
```

Fix: add an explicit `return <default>` **after** the closing `}` of the
`while` block. The line is unreachable at runtime but satisfies the compiler.

```monkey-c
static function persist(…) as Lang.Boolean {
    while (true) {
        if (…) { return true; }
        if (…) { return false; }
        // evict and retry
    }
    return false;  // unreachable — required by monkeyc
}
```

## `TileDecoder.load()` watchdog via byte-copy loop

**Symptom.** Watch crashes in `onUpdate()` with stack pointing to
`TileDecoder.mc load()` ← `NavigationView.mc loadBundle()` ← `ensureBundleLoaded()`.
Error: `Watchdog Tripped Error - Code Executed Too Long`.

**Root cause.** The old `load()` pre-allocated the destination blob
(`new [sz]b`) and then assembled it using a Monkey C byte-copy loop:
```monkeyc
for (var ci = 0; ci < chSize; ci++) { blob[writeOff + ci] = ch[ci]; }
```
For a 65 KB bundle (5 × 16 KB Storage chunks), that's ~65 000 iterations
at ~4 bytecodes each ≈ 260 000 bytecodes — far over the watchdog limit.

**Fix.** Always use `new [0]b` + `blob.addAll(chunk)` per Storage chunk.
`addAll()` is a native C++ call — regardless of how many bytes it copies,
it costs only ~3 Monkey C bytecodes. The N² native-side memory copies
(~130 KB total for a 65 KB blob over 5 chunks) are sub-millisecond.
See `TileDecoder.load()`.

**Rule.** Never use a Monkey C byte-copy loop (`arr[i] = src[i]`) on
ByteArrays larger than a few hundred bytes. Use `addAll()` instead.
The watchdog counts Monkey C bytecodes, not CPU time — native calls are
effectively free.

## `Math.exp` undefined in Connect IQ SDK 9.1.0 / fenix7

**Symptom.** `monkeyc` fails with:

```
ERROR: fenix7: NavigationView.mc:453,8: Undefined symbol ':exp' detected
```

**Root cause.** `Math.exp(x)` does not exist in the SDK 9.1.0 API for fenix7.

**Fix.** Use `Math.pow(Math.E, x)` instead. `Math.E` is a predefined constant;
`Math.pow` is available. For `sinh(x)` specifically:

```monkeyc
var ex = Math.pow(Math.E, x).toFloat();
var sinhVal = (ex - 1.0f / ex) * 0.5f;
```

**Where this matters.** `tileYToLat()` in `NavigationView.mc` uses this
pattern for Web Mercator Y → latitude conversion. Never write `Math.exp(...)`.

## Tiles decode successfully but are invisible (off-screen projection)

**Symptom.** Badge shows "[NS] ok" (tiles decoded), route polyline is visible,
but the map background is black. Debug shows something like `t0 -61935,36164 118x116`
— huge negative X or huge positive Y, but w×h are plausible (~100–130 px for zoom 13).

**The architecture.** We use `tileScreenRect()` + `dc.drawScaledBitmap()`:
each tile's `(zoom, tileX, tileY)` from the GMND entry is converted to Web
Mercator lon/lat bounds via `tileScreenRect`, projected to screen pixels via
`projectPoint()`, and blitted scaled. If w×h are reasonable, the formula ran
correctly — only the position is wrong.

**Root causes when position is wildly off:**

1. **Bundle and route are from different geographic regions.** The bundle was
   generated during a previous sync for region A; the current test sends a
   route from region B. Fix: always re-sync map bundle together with the route.
   Diagnostic: see "How to diagnose" below.

2. **`applyRoute()` not called before `ensureBundleLoaded()`.** If the route
   hasn't been received yet, `_viewLon0 = _viewLon1 = 0.0` and `projectPoint()`
   maps tile coords relative to lon 0° (prime meridian). This happens when
   `tile_session` arrives before the route chunks complete. Fix confirmed:
   `ensureBundleLoaded()` runs at the very top of `onUpdate()`, before the
   `!_route.isComplete` guard — the viewport only needs to be set, not the route.
   `applyRoute()` sets the viewport as soon as the first route_start message
   arrives, which is always before tile_session.

**How to diagnose — read tileX/tileY from debug:**
```monkeyc
pushDebug("t0 z=" + t.zoom + " tx=" + t.tileX + " ty=" + t.tileY);
```
Compare against expected values for zoom 13. For Kyiv (lat ≈ 50.45, lon ≈ 30.52):
`tileX ≈ 4789, tileY ≈ 2759`. If actual values are far off, the bundle is
from a different region. General formula:
```
n = 2^zoom
tileX = floor((lon + 180) / 360 * n)
tileY = floor((1 − ln(tan(latRad) + 1/cos(latRad)) / π) / 2 * n)
```

## `Communications.transmit()` rejects `null` ConnectionListener

**Symptom.** `monkeyc` build fails at the `Communications.transmit(data, params, null)` call:

```
Invalid 'Null' passed as parameter 3 of type '$.Toybox.Communications.ConnectionListener'.
```

**Fix.** `Communications.transmit()` requires a concrete `ConnectionListener`
object. Create a minimal no-op subclass:

```monkeyc
class NullConnectionListener extends Communications.ConnectionListener {
    function initialize() { Communications.ConnectionListener.initialize(); }
    function onComplete() as Void {}
    function onError() as Void {}
}
```

Pass `new NullConnectionListener()` as the third argument. This class lives
in `GarmiandApp.mc`. Never pass `null` for any typed CIQ parameter.
