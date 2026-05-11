# Connect IQ Notes

Hard-won facts about Connect IQ, Garmin Connect Mobile (GCM), and the Fenix 7. Read this before changing anything that crosses the BLE boundary.

## The proxy model

The watch has no IP stack. When watch code calls `Communications.makeImageRequest(url, ...)` or `Communications.makeWebRequest(url, ...)`, the call is forwarded over BLE to GCM running on the phone. **GCM makes the actual HTTP(S) request**, processes the image (resize, dither), and ships bytes back to the watch.

Implications:
- Network reachability is a property of the phone, not the watch.
- HTTPS cert validation is done by GCM, not by us.
- There is no streaming — the response is materialized in full before the watch sees a single byte.

## MapView — not used (abandoned, see ADR-008)

`NavigationView` currently extends `WatchUi.View`, not `WatchUi.MapView`.
MapView was tried and removed because `MapView.onUpdate()` crashed
consistently in the Connect IQ simulator, blocking development.

Remaining relevant facts if MapView is ever revisited:
- **There is no `Map` permission.** `<iq:uses-permission id="Map"/>` errors
  with "Invalid permission provided: Map" at compile time.
- **There is no `latLonToScreenPoint(loc)` API.** This was the biggest
  surprise — Connect IQ doesn't let you map a coordinate to a pixel, so
  custom overlays (polyline, waypoints, GPS dot) always require manual
  projection math.
- `MAP_MODE_PREVIEW` gives a static viewport via `setMapVisibleArea`;
  `MAP_MODE_BROWSE` lets the user pan/zoom but you can't read the resulting
  viewport, making overlay alignment impossible.

All modes in the current code use manual `projectPoint()` projection:
`_viewLat0/1, _viewLon0/1` tracks the bounding box set at `applyRoute()`,
and points are mapped to pixel coords via linear lon/lat → fraction → pixel.

## Application.Storage limits

`Application.Storage.setValue/getValue/deleteValue` accepts strings, numbers,
arrays, dictionaries, and `Lang.ByteArray`. Per-app total is empirically
~128 KB on Fenix 7 (Garmin doesn't document this).

**Critical: per-value limit is ~32 KB** (empirically confirmed in the
simulator; likely similar on device). Calling `setValue` with a `ByteArray`
larger than this causes an unhandled OOM crash — `StorageFullException` is
**not** thrown, the app just dies. This is distinct from the total-size limit.

We work around this by chunking the blob into 16 KB pieces:
- `b_<first8ofId>_0`, `_1`, … `_N-1` — the raw chunks
- `b_<first8ofId>_n` — number of chunks (Number)
- `b_<first8ofId>_sz` — total byte count (Number)

`TileDecoder.persist/load/deleteBundle` manage these keys. When loading,
`TileDecoder.load()` uses `new [0]b` + `blob.addAll(chunk)` for each Storage
chunk. `addAll()` is native C++ — it costs ~3 Monkey C bytecodes regardless of
data size, avoiding the watchdog trip that a Monkey C byte-copy loop causes for
bundles > ~20 KB.

BLE WIP state uses a separate key set (prefix `ble_wip_`) — see API_CONTRACTS.md.
These keys accumulate one entry per received chunk (`ble_wip_c_N`) and are
cleared by `BleChunkAssembler.clearWip()` once assembly completes.

If `setValue` throws `StorageFullException` (total limit), delete old bundle
keys (simulator's `Settings → Edit Storage`) or reduce bundle size.

## Touch events: DragEvent / ClickEvent / FlickEvent (not TouchEvent)

SDK 9.1.0 / fenix7 exposes touch through **three separate event classes**, not
a unified `TouchEvent` with a type field. `WatchUi.TOUCH_TYPE_PRESS` and
`TOUCH_TYPE_RELEASE` are **undefined** in this SDK — using them causes a
compile-time "Undefined symbol" error.

| Class | Handler in `InputDelegate` | Fires when |
|---|---|---|
| `ClickEvent` | `onTap(evt as ClickEvent)` | Quick finger tap |
| `DragEvent`  | `onDrag(evt as DragEvent)` | Finger held and moving |
| `FlickEvent` | `onFlick(evt as FlickEvent)` | Fast swipe (also triggers `BehaviorDelegate.onSwipe`) |

`DragEvent` constants (API since 3.3.0):
- `WatchUi.DRAG_TYPE_START` — first event when drag begins
- `WatchUi.DRAG_TYPE_CONTINUE` — intermediate events as finger moves
- `WatchUi.DRAG_TYPE_STOP` — last event when finger lifts

All three classes expose `getCoordinates()` returning the current `[x, y]`.
`DragEvent.getType()` returns one of the `DRAG_TYPE_*` values.

**Enabling touch events.** Call `WatchUi.configureTouchEvents({:enabled => true})`
from `AppBase.onStart()` (API since 5.2.0). For apps targeting only Fenix 7,
which ships with API ≥ 5.x firmware, this is safe without a version guard.
The default state is implementation-defined; calling it explicitly is the
only guaranteed way to activate drag events.

**Interaction with `BehaviorDelegate`.**
`BehaviorDelegate` maps `ClickEvent` → `onSelect` and `FlickEvent` (direction
UP/DOWN) → `onNextPage`/`onPreviousPage`. Overriding `onDrag` in a
`BehaviorDelegate` subclass intercepts drag events independently — it does not
conflict with the tap/swipe mappings. Return `true` to consume, `false` to
propagate to the base-class handler.

## `Math.exp` does not exist; use `Math.pow(Math.E, x)`

`Math.exp(x)` is absent from the SDK 9.1.0 fenix7 API.
`monkeyc` errors with `Undefined symbol ':exp' detected`.

Use `Math.pow(Math.E, x)` instead. `Math.E` is a predefined constant.
For `sinh(x)`:
```monkeyc
var ex = Math.pow(Math.E, x).toFloat();
var sinh = (ex - 1.0f / ex) * 0.5f;
```

## `dc.drawScaledBitmap` for scaled tile rendering

`Graphics.Dc.drawScaledBitmap(x, y, w, h, bmp)` is available in SDK 9.1.0 /
fenix7 and is the correct way to render a `BufferedBitmap` at a size other
than its native dimensions. Use this — not `drawBitmap` — whenever the tile's
screen rect differs from its pixel size (which is always the case for
geographically-sized tiles). The scaling is done by the graphics engine at
negligible VM cost.

**Behavior with off-screen coordinates.** If `x` or `y` is far off-screen
(e.g. `x = -61935`), `drawScaledBitmap` silently does nothing — no error,
no partial draw. This makes region-mismatch bugs invisible: the tiles decode
successfully, the draw call fires, but nothing appears. Always verify tile
screen position via `pushDebug` before concluding `drawScaledBitmap` is broken.
See "Tiles decode successfully but are invisible" in `bug_fixes.md`.

## BufferedBitmap with palette

`Graphics.createBufferedBitmap({:width, :height, :palette})` returns a
`BufferedBitmapReference`. Call `.get()` to get the actual `BufferedBitmap`.
Pixel-filling is done via `bmp.getDc()` + `setColor` + `fillRectangle`
(run-length per column). Per-frame rendering uses
`dc.drawScaledBitmap(x, y, w, h, bmp)` (not `drawBitmap`) so tile geographic
extent maps correctly to screen pixels regardless of zoom level.

**`getBuffer()` does not exist on fenix7 / SDK 9.1.0.** The method that
would return the backing `ByteArray` for direct index writes is not in the
API; `monkeyc` errors with "Undefined symbol ':getBuffer'". All pixel writes
must go through Dc calls.

**Watchdog reality:** a 128×128 tile = 16 384 pixels. Even with RLE
(`fillRectangle` on color runs), processing the whole tile in one `onUpdate`
call trips the watchdog in the simulator. We process **8 columns per
`onUpdate` frame** (`TileDecoder.fillTileColumns`), which gives ~1 024
inner-loop iterations per frame — comfortably within budget. The `BufferedBitmap`
Dc is held between frames; the bmp is only added to `_decodedTiles` when all
columns are done.

**Watchdog budget: callbacks vs `onUpdate`.**
HTTP response callbacks (`onBundleChunkResponse`) and BLE message handlers
(`onPhoneMessage`) have a **shorter** watchdog budget than `onUpdate`. Do not
call `TileDecoder.load()` (even with `addAll`) or `createBufferedBitmap` from
inside those callbacks. Use the deferred pattern: set a flag (`_bundleLoadAttempted = false`)
and let `ensureBundleLoaded()` in `onUpdate` do the heavy lifting.

Graphics memory pool on Fenix 7 is ~256 KB. A 128×128 indexed bitmap takes
~16 KB. Four decoded tiles + the screen Dc fits comfortably.

## makeWebRequest response buffer limit

`Communications.makeWebRequest` with `HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN`
has an undocumented response buffer cap of approximately 12–16 KB. Attempting
to receive a larger response (e.g. a 65 KB bundle base64-encoded as ~87 KB)
returns error code **`-402` (NETWORK_RESPONSE_OUT_OF_MEMORY)**.

**`HTTP_RESPONSE_CONTENT_TYPE_BYTE_ARRAY` does not exist** in the Connect IQ
API. The only binary-adjacent option is TEXT_PLAIN with base64.

Our workaround: the server exposes
`GET /sessions/:id/chunk?offset=N&size=10240` which returns a 10 KB slice.
The watch makes sequential requests, writing each decoded chunk into a
pre-allocated `ByteArray` (`_dlBuffer = new [_dlTotal]b`) at the correct
offset. Progress: `_dlOffset += chunkSize`, next request starts when the
callback fires. No reallocation, no heap fragmentation.

**`new [0]b` vs `[] as Lang.ByteArray`:** only the former creates a true
`Lang.ByteArray`. `[] as Lang.ByteArray` is syntactically accepted by
`monkeyc` but creates a regular `Lang.Array`, which crashes at runtime when
you call `.addAll()` on it (`UnexpectedTypeException: Expected Array, given ByteArray`).
Always use `new [N]b` (fixed size) or `new [0]b` (empty, grow with addAll).

## Communications.transmit chunking and resumable BLE transfer

For BLE-direct bundle delivery the phone sends a series of `tile_chunk`
messages (each ≤3072 bytes), preceded by a `ble_bundle_start` handshake.

**Handshake flow:**
1. Phone sends `ble_bundle_start` (bundle_id, total chunk count, total bytes).
2. Watch checks WIP Storage; transmits `ble_wip_report` with already-received
   chunk indices (empty list = start from zero). Uses `Communications.transmit()`
   with a `NullConnectionListener` — **null is not accepted**.
3. Phone waits up to 3 s (CountDownLatch); on timeout sends all chunks.
4. Phone skips indices the watch already has.

**Watch-side processing:** `onPhoneMessage` only queues the chunk dict into
`_pendingTileChunk`. `GarmiandApp.processPendingTileChunk()`, called from
`NavigationView.onUpdate()`, does the actual `BleChunkAssembler.accept()` call.
This avoids the BLE-callback watchdog. Critical ordering: in `onUpdate()`,
`processPendingPersist()` must run **before** `processPendingTileChunk()`.

**WIP persistence:** After each successful `accept()`, the chunk payload is
written to `App.Storage["ble_wip_c_N"]`. On `onStart()`, if WIP keys exist,
the assembler is restored via `BleChunkAssembler.loadWip()`.

**Safety timer (phone side):** `MapBundleBleSender` pauses 10 s every 2 minutes
of continuous sending (`MAX_CONTINUOUS_MS = 120 000`, `SAFETY_PAUSE_MS = 10 000`)
to give the watch's `onUpdate()` loop time to drain queued chunks.

A 10-second stall timer (`_bleStallTimer`) on the watch is armed after each
chunk and reset on each subsequent one. If the phone stops mid-transfer the
timer fires, logs missing indices, and sets the assembler to null (buffer freed;
WIP keys remain in Storage for later restore).

## What GCM will and won't proxy

| URL | Result |
|---|---|
| `https://tile.openstreetmap.org/...` | ✅ Works. Verified with the production app. |
| `https://staticmap.openstreetmap.de/...` | Got a 404 — service is dead, but the request *did* leave GCM. |
| `http://192.168.x.x:8081/...` (LAN IP, phone-local) | ❌ Silent. Server logs nothing. GCM blocks or never sends. |
| `http://127.0.0.1:8081/...` | ❌ Same as above. |

Conclusion: **public HTTPS only.** See ADR-003.

## Phone-app message dictionaries

- The serialization is native: `Map<String, Any>` on Kotlin → `Lang.Dictionary` on the watch.
- **Keys arrive on the watch as `String`**, not `Symbol`. `dict["kind"]` works; `dict[:kind]` does not.
- Values come through as their nominal type but may need explicit casting:
  - Numerics may arrive as `Lang.Number` or `Lang.Float`. Cast via `(dict["x"] as Lang.Numeric).toFloat()`.
  - Arrays of doubles arrive as `Lang.Array<Lang.Numeric>`; coerce to `Float` when storing.
- Maximum message size is roughly 4 KB. We chunk routes at 50 points/message — well under that.

## `IQMessageStatus.SUCCESS` is not application-level

It means GCM-to-watch BLE delivery succeeded. The watch may still reject the dictionary, fail to parse, or simply never make the follow-up `makeImageRequest`. **Don't conflate ack with correctness.**

## `Communications.makeImageRequest` response codes

`responseCode` in the callback is either an HTTP status (200, 404, 403) **or** a negative Connect IQ error. The ones we've actually seen:

| Code | Meaning |
|---|---|
| `200` | OK. `data` is a `BitmapResource`. |
| `404` | The remote returned 404 (or DNS-resolved to a catchall that did). |
| `403` | Likely tile-server rate limit or User-Agent block. |
| `-300` to `-104` | Various Connect IQ-internal errors (timeouts, oversized response, OOM). The names are in the SDK docs. |

We surface this on the watch via the yellow bottom-banner (`MAP code=… d=…`).

## Position events on the simulator

`Position.enableLocationEvents(...)` registered from anywhere other than `AppBase` will not fire its callback in the simulator. Even at `AppBase` it can be flaky. We register at `AppBase` *and* poll `Position.getInfo()` once per second (Timer fallback). Don't move the registration into `GpsListener` — that broke once already.

## On-device logging

- `System.println` output is captured by the simulator (`monkeydo` stdout), but **not surfaced on physical hardware** for sideloaded apps.
- `CIQ_LOG.YML` on the watch (`GARMIN/APPS/LOGS/`) only writes for unhandled exceptions; it is not a general log.
- For meaningful diagnostics on hardware, **paint the value onto the screen** (we use a yellow debug band at the bottom of `NavigationView`).

## Manifest gotchas

- `<iq:application id="...">` must match Android's `WATCH_APP_ID` byte-for-byte. If the IDs drift, GCM's `getApplicationInfo` returns "not installed" even when the `.prg` is on the watch.
- `<iq:uses-domain>` is required for Store-published apps but not for sideloaded development builds. Don't add one preemptively — it can break local testing.

## Sideload sanity check

After dropping `.prg` into `GARMIN/APPS/`, the watch needs to be re-seen by GCM. If `getApplicationInfo` keeps returning not-installed:
1. Force-stop and reopen GCM.
2. On the watch, open the app once manually from `Activities & Apps`.
3. Confirm Bluetooth is connected (top-left bar).
