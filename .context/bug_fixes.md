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

## BleChunkAssembler watchdog crash during final assembly

**Symptom.** Watch crashes after receiving the last BLE chunk (e.g. 4/6 or
6/6 received), with `CIQ_LOG.YML` showing:

```
Error: 'Watchdog Tripped Error - Code Executed Too Long'
Stack: BleChunkAssembler.mc line 95, accept / GarmiandApp.mc handleTileChunk / onPhoneMessage
```

**Root cause.** The old `BleChunkAssembler` stored each received chunk as a
`ByteArray` value in a `Dictionary<Number, ByteArray>`. On the final chunk it
assembled the blob by iterating over all chunks and copying byte-by-byte into
a new array — for a 65 KB bundle at 3 KB chunks that's ~65 000 byte copies in
a single `onPhoneMessage` callback, which exceeds the watchdog budget.

**Fix.** Streaming pre-allocation: on the first chunk, allocate a single
`_blob = new [totalBytes]b` from the `tb` field. Each subsequent chunk is
written directly at `offset = i × chunkSize`, so the final-assembly loop
is eliminated entirely. The per-chunk byte-copy is ~3 072 iterations — safe
for the watchdog. See `BleChunkAssembler.accept()`.

**Invariant.** The `tb` field in `tile_chunk` must be the uncompressed bundle
size in bytes. `MapBundleBleSender` sets `totalBytes = bundle.size` in every
chunk. If `tb` is absent, the assembler falls back to dynamic `addAll` growth
(slower, and the final-assembly watchdog risk returns).

## BLE chunk stall detection

If the phone stops sending mid-transfer (e.g. BLE drop, user navigates away),
the watch has a pre-allocated `_blob` buffer pinned in RAM with no way to
know the transfer is dead. A 10-second one-shot `Timer` (`_bleStallTimer` in
`GarmiandApp`) is armed after each chunk and re-armed on each subsequent
chunk. If no chunk arrives within 10 s:

- `onBleStallTimeout()` logs `BLE STALL N/M missing=[...]` with which
  chunk indices were not received.
- `_bleChunkAssembler` is set to `null`, freeing the pre-allocated buffer.
- The assembler is recreated fresh if the phone retries.

The stall timer is disarmed immediately when the final chunk completes.

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
