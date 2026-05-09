# Connect IQ Notes

Hard-won facts about Connect IQ, Garmin Connect Mobile (GCM), and the Fenix 7. Read this before changing anything that crosses the BLE boundary.

## The proxy model

The watch has no IP stack. When watch code calls `Communications.makeImageRequest(url, ...)` or `Communications.makeWebRequest(url, ...)`, the call is forwarded over BLE to GCM running on the phone. **GCM makes the actual HTTP(S) request**, processes the image (resize, dither), and ships bytes back to the watch.

Implications:
- Network reachability is a property of the phone, not the watch.
- HTTPS cert validation is done by GCM, not by us.
- There is no streaming — the response is materialized in full before the watch sees a single byte.

## MapView basics

We extend `WatchUi.MapView` (not `WatchUi.View`) for the map screen. Notes from getting it to compile against SDK 9.1.0:

- **There is no `Map` permission.** `<iq:uses-permission id="Map"/>` errors with
  "Invalid permission provided: Map" at compile time. MapView is gated by
  device capabilities, not manifest permissions.
- We use `WatchUi.MAP_MODE_PREVIEW` (not `MAP_MODE_BROWSE`). PREVIEW gives
  static rendering whose viewport we control via `setMapVisibleArea`. BROWSE
  would let the user pan/zoom but Connect IQ does not expose a way to read
  the resulting viewport, so we'd have no way to align our overlays. Trade-off:
  in NATIVE mode the user can't pan/zoom — they pick the viewport at sync time
  by virtue of route bbox + 15% padding.
- `setMapVisibleArea(topLeft as Position.Location, bottomRight as Position.Location)` —
  TWO Location objects, not center+spans. `topLeft` has the higher latitude
  (north) and lower longitude (west); `bottomRight` is the opposite corner.
- `MapPolyline.addLocation(loc | Array<loc>)`, then `MapView.setPolyline(poly)`.
  Color (`setColor`) and width (`setWidth`) are properties of `MapPolyline`.
- `MapMarker(location)` constructor takes one Location; `setLabel(text)` and
  `setIcon(bmp)` decorate it. **`MapView.setMapMarker` accepts a single marker
  OR an `Array<MapMarker>`** — we pass the array form for waypoints + GPS.
- **There is no `latLonToScreenPoint(loc)` API.** This was the big surprise.
  In NATIVE mode we accept that, hand off to MapView's native polyline/marker
  rendering, and only draw the top band + OFF ROUTE banner manually
  (fixed-position UI, no projection). In TILES/NONE modes we project route
  points ourselves from our tracked viewport (`_viewLat0/1, _viewLon0/1`)
  using a linear lon/lat → fraction → pixel conversion (`projectPoint(dc, lat, lon)`
  in `NavigationView.mc`).

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
we reconstruct via `blob.addAll(chunk)` (bulk copy, not byte-by-byte).

If `setValue` throws `StorageFullException` (total limit), delete old bundle
keys (simulator's `Settings → Edit Storage`) or reduce bundle size.

## BufferedBitmap with palette

`Graphics.createBufferedBitmap({:width, :height, :palette})` returns a
`BufferedBitmapReference`. Call `.get()` to get the actual `BufferedBitmap`.
Pixel-filling is done via `bmp.getDc()` + `setColor` + `fillRectangle`
(run-length per column). Per-frame rendering uses `dc.drawBitmap(x, y, bmp)`.

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

## Communications.transmit chunking

For BLE-direct bundle delivery we send a series of `tile_chunk` messages,
each with `:p` set to a `ByteArray` ≤3000 bytes (Garmin per-message limit
is documented as ~4 KB; we keep headroom). Garmin throttles concurrent
sends — 3 outstanding requests max — so the Android side spaces chunks by
~150 ms. The watch reassembles by `i` (index), so out-of-order arrival is
tolerated.

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
