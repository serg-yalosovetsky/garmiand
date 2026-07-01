# Map Rendering

How the watch ends up with a usable map under the polyline. Three modes, two
delivery transports, one binary format.

## Modes (`map_mode` property in `properties.xml`)

| Mode | Value | Backdrop | When to use |
|---|---|---|---|
| `NATIVE` | 0 | TopoActive vector map (pre-installed on Fenix 7) | default; works in user's home region without any sync |
| `TILES`  | 1 | Quantized raster bundle from `Application.Storage` | regions outside TopoActive, or to overlay a different style |
| `NONE`   | 2 | Black background | bandwidth-conscious, polyline-only |

Mode is changed via the Connect IQ Settings UI (picker defined in
`garmin/resources/settings.xml`) or in-app via the **SELECT** button
(`NavigationDelegate.onSelect` cycles modes).

The polyline, waypoint markers, route name, and OFF ROUTE banner are drawn
**on top** in every mode, so switching modes never hides the route.

## Delivery transports (TILES mode only)

Both paths produce the same binary blob and write it to
`Application.Storage["bundle_<bundleId>"]`. The watch decoder doesn't care
which path was used.

### HTTPS (preferred, requires phone connectivity)

1. `MainActivity.sendMapBundle` → `TileQuantizer.quantizeMultiZoom(points)` produces a
   `QuantizedBundle` with tiles at OSM zoom levels 12, 13, and 15 interleaved.
2. `TileBundleSerializer.serialize(bundle)` → `ByteArray`.
3. `MapBundleUploader` POSTs to `${BACKEND_URL}/sessions` with the bundle as
   `application/octet-stream`. Server responds with
   `{sessionId, downloadUrl}`.
4. Phone sends `tile_session` BLE message with `bundle_id` and `download_url`.
5. Watch (`GarmiandApp.handleTileSession`) calls
   `Communications.makeWebRequest(url, ..., HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN)`.
   The server returns the bundle **base64-encoded as plain text** because
   Connect IQ's `makeWebRequest` cannot deliver raw octet streams.
6. Watch base64-decodes via `StringUtil.convertEncodedString(...)`,
   `TileDecoder.persist(id, blob)` writes to Storage, and
   `NavigationView.setBundleId` triggers decode.

### BLE direct (fallback, no internet required)

1. Same Phase 1-2 above (quantize + serialize).
2. `MapBundleBleSender.send(blob)` chunks the blob into 3000-byte pieces.
3. Each chunk is a `tile_chunk` BLE message with `bundle_id`, `i`, `n`, `p`
   (`p` is `Lang.ByteArray` on the wire).
4. Watch's `BleChunkAssembler` indexes chunks by `i`. When `_receivedCount`
   reaches `n`, the chunks are concatenated and persisted.

## Wire format (the `GMND` envelope)

Defined in `TileBundleSerializer.kt` and parsed in `TileDecoder.mc`. All
multi-byte ints are big-endian; floats are IEEE-754 single.

```
offset  size  field
0       4     magic = "GMND"
4       1     version = 1
5       1     paletteSize  (= 64 in v1)
6       2     tileCount    (uint16)
8       16    bbox         (4 × float32: minLat, maxLat, minLon, maxLon)
24      P*3   palette      (P × RGB888)
24+P*3  T*21  tile entries
...           tile pixel arrays (column-major, 1 byte = palette index 0..63)
```

Each tile entry (21 bytes):
```
0     1   zoom
1     4   tileX (uint32)
5     4   tileY (uint32)
9     2   width (uint16)
11    2   height (uint16)
13    4   pixelOffset (uint32, absolute byte offset in blob)
17    4   pixelLength (uint32)
```

## Quantization (`map/Palette.kt`)

The 64-color palette is a 4×4×4 RGB cube, evenly spaced (levels = 0/85/170/255 per channel). Index = `(r << 4) | (g << 2) | b`. The palette is a fixed
constant on both phone and watch — any change to it invalidates every
existing bundle in `Application.Storage`. Bump `Palette.VERSION` and the
`version` field in the `GMND` header together.

## Decoder pipeline (`TileDecoder.mc` + `NavigationView.mc`)

Decoding is split into three phases to stay within the Connect IQ watchdog.

**Phase 0 — Storage assembly.** `TileDecoder.load(bundleId)` reads the blob
from up to 5 storage keys (`b_<id>_0 … b_<id>_4`, each ≤16 KB) and
concatenates them with `ByteArray.addAll()` (bulk, not byte-by-byte).

**Phase 1 — Header + entry parsing.** `NavigationView.loadBundle()` calls
`TileDecoder.parseHeader()` and `parsePalette()` (fast, ~300 bytes read).
Then `prepareDecode(blob, hdr)` iterates all tile entries (21 bytes × tileCount)
and stores only those whose `zoom == _activeOsmZoom` into `_pendingEntries`.
The full blob is kept in `_pendingBlob` — tiles from other zoom levels remain
in the blob but are not decoded. Each retained entry holds `(zoom, tileX, tileY)`
for use at render time.

**Phase 2 — Incremental pixel decode.** `NavigationView.decodeNextTile()` is
called from `onUpdate()` once per frame. Each call:
1. Allocates a `Graphics.BufferedBitmap` for the current tile if not yet done.
2. Calls `TileDecoder.fillTileColumns(blob, entry, palette, bdc, startCol, 8)` —
   fills exactly 8 columns (= `8 × tileHeight` iterations) into the bitmap's
   persistent Dc. With RLE per column (`fillRectangle` on runs of same color),
   this is typically 200–400 DC calls, well within the 2-second watchdog.
3. Advances `_pendingColIndex += 8`. When `_pendingColIndex >= entry.width`,
   the completed `BufferedBitmap` is added to `_decodedTiles` as a `DecodedTile`
   (holds `bmp`, `zoom`, `tileX`, `tileY`).
4. `onUpdate()` calls `WatchUi.requestUpdate()` while tiles remain pending.

Decode time: `N × (tileWidth ÷ 8)` frames. With z13 128×128 tiles and 12 tiles:
`12 × 16 = 192 onUpdate` cycles. z12 64×64 tiles: `4 × 8 = 32` cycles.

**Important constraints discovered in testing:**
- `Graphics.BufferedBitmapType.getBuffer()` does **not exist** in SDK 9.1.0 /
  fenix7 — `monkeyc` fails with "Undefined symbol ':getBuffer'". All pixel
  writes must go through the Dc API.
- A single 128×128 tile (16 384 DC calls) trips the watchdog even in `onUpdate`.
  RLE helps but is not sufficient alone — the 8-columns-per-frame limit is
  required.
- `loadBundle()` must not be called from inside an HTTP/BLE callback; those
  have a shorter watchdog budget than `onUpdate`. `setBundleId()` only sets
  `_bundleLoadAttempted = false`; the actual load happens via
  `ensureBundleLoaded()` at the top of `onUpdate()`, before the
  `_route.isComplete` guard (otherwise the guard short-circuits the load).

Decoded `BufferedBitmap` instances live in `NavigationView._decodedTiles`. Each
is blitted via `dc.drawScaledBitmap(sx, sy, sw, sh, bmp)` in `drawCustomTiles`,
where `(sx, sy, sw, sh)` comes from `tileScreenRect()` — see below.

## Layout in TILES mode — Web Mercator tile positioning

Each tile knows its XYZ tile coordinates `(zoom, tileX, tileY)` from the
GMND entry. At render time `tileScreenRect(t)` converts those coords to
screen pixels via Web Mercator inverse:

```
n = 1 << zoom
lonNW = tileX / n * 360 - 180
lonSE = (tileX+1) / n * 360 - 180
latNW = tileYToLat(tileY, n)      // atan(sinh(π*(1-2*ty/n)))
latSE = tileYToLat(tileY+1, n)
nw = projectPoint(latNW, lonNW)   // → screen pixel [px, py]
se = projectPoint(latSE, lonSE)
sw = se[0]-nw[0]  sh = se[1]-nw[1]
```

Then `dc.drawScaledBitmap(nw[0], nw[1], sw, sh, t.bmp)` scales the 128×128
`BufferedBitmap` to exactly cover its geographic extent on screen. This is
the only correct approach: at zoom 13, one tile spans ~0.022°lat × 0.044°lon
while a typical route viewport is only ~0.01°lat wide, so "draw at native
pixel size" places tiles 250+ px off-screen.

`tileYToLat` requires `sinh(x)` which is computed as
`(Math.pow(Math.E, x) - 1/Math.pow(Math.E, x)) * 0.5` because
`Math.exp` does **not exist** in SDK 9.1.0 / fenix7.

Polyline / waypoint / GPS-position overlays project route points using a
manual viewport (`_viewLat0/1, _viewLon0/1` set by `applyRoute` from the
route bbox + 15% padding). There is no `latLonToScreenPoint` in the
Connect IQ API, so pixel positions are computed by linear fraction-of-viewport
via `projectPoint()`. All three modes use identical `projectPoint()` logic.

## Troubleshooting tile visibility

**Symptom: "[NS] ok" badge, polyline visible, map black.**

Step 1 — confirm `tileScreenRect` has valid input. Add to `drawCustomTiles`:
```monkeyc
pushDebug("t0 z=" + t.zoom + " tx=" + t.tileX + " ty=" + t.tileY);
```
If the message shows `t0 null` instead, the viewport is unset — `applyRoute()`
hasn't fired. If it shows coordinates, proceed to step 2.

Step 2 — compare `tileX/tileY` against expected values for the route's region.
For zoom 13, Kyiv (lat ≈ 50.45, lon ≈ 30.52): `tileX ≈ 4789, tileY ≈ 2759`.
If actual values differ by hundreds, the stored bundle is from a different
region. Fix: re-sync map bundle together with the current route.

Step 3 — if tileX/tileY are correct but debug shows wildly negative x (e.g.
`t0 -61935,36164 118x116`), there is a projection mismatch: the viewport
`_viewLon0/1` does not bracket the tile's longitude. Check that `applyRoute()`
was called with the current route (not stale data) and that `_viewSet = true`.

`drawScaledBitmap` with correct coordinates draws on-screen at the expected
position; with off-screen coordinates it silently draws nothing.

## Zoom and pan modes

### Touch drag (primary pan method)

`NavigationDelegate.onDrag(evt as WatchUi.DragEvent)` handles finger-drag
events, which the Connect IQ framework fires continuously as the finger moves:

- `DRAG_TYPE_START` — stores the initial finger position in `_dragPrevX/Y`.
- `DRAG_TYPE_CONTINUE` — computes `(dx, dy)` delta from the previous position,
  calls `NavigationView.panByPixels(dx, dy)`, updates `_dragPrevX/Y`.
- `DRAG_TYPE_STOP` — same as CONTINUE for the final event.

`panByPixels(dx, dy)` converts screen-pixel delta to geographic delta:
```
latPerPx = halfLat * 2 / screenH    (halfLat = viewport lat span / 2 / zoomFactor)
lonPerPx = halfLon * 2 / screenW
_panOffsetLat += dy * latPerPx      (dy > 0 = finger down = reveals north)
_panOffsetLon -= dx * lonPerPx      (dx > 0 = finger right = reveals west)
```

Drag events are active in all modes (NATIVE/TILES/NONE) whenever the route
viewport is set. BehaviorDelegate separately maps tap → `onSelect` →
`cycleMapMode()`, so no override of `onTap` is needed.

Touch events must be enabled explicitly; `GarmiandApp.onStart()` calls
`WatchUi.configureTouchEvents({:enabled => true})`.

### Physical button sub-modes (SELECT cycle)

The SELECT button cycles through four interact sub-modes; a fourth press in
JUMP mode exits TILES entirely (returns to NATIVE). Badge shown in top band:

| `_interactMode` | Constant | Badge | UP / DOWN action |
|---|---|---|---|
| 0 | `INTERACT_ZOOM`   | `ZOOM` | zoom in (×1.5) / zoom out (÷1.5) |
| 1 | `INTERACT_PAN_NS` | `NS`   | pan north / pan south |
| 2 | `INTERACT_PAN_WE` | `WE`   | pan west / pan east |
| 3 | `INTERACT_JUMP`   | `JMP`  | UP = center on GPS, DOWN = center on route |

**Zoom implementation.** `_zoomFactor` (range 0.25–16.0, default 1.0) divides
`halfLat` / `halfLon` inside `projectPoint()`:
```
effHalfLat = halfLat / _zoomFactor
effHalfLon = halfLon / _zoomFactor
```
Higher factor → smaller effective viewport → zoom in. Pan steps are also
divided by `_zoomFactor` so panning speed stays proportional to the view size.
`_zoomFactor` resets to 1.0 in `applyRoute()`, `centerToGps()`, and `centerToRoute()`.

Every time `_zoomFactor` changes in ZOOM mode, `checkZoomSwitch()` is called.
If the new value crosses an OSM zoom threshold, `_activeOsmZoom` is updated and
tile re-decode is queued (see Multi-zoom tile bundles above). The top-band mode
badge reflects the active OSM zoom: e.g. `ZOOM z13 ok`, `ZOOM z15 dec`.

## Native rendering (NATIVE mode)

`NavigationView` extends `WatchUi.View` (MapView was removed — see ADR-008).
NATIVE mode draws a plain black background, then the same manual polyline /
waypoint / GPS-position overlays as TILES and NONE. There is no Garmin
TopoActive backdrop in the current implementation.

## Multi-zoom tile bundles

A single `GMND` bundle may contain tiles at multiple OSM zoom levels.
`quantizeMultiZoom()` fetches three corridors and merges them:

| OSM zoom | Output size | Buffer | Max tiles | Blob size |
|---|---|---|---|---|
| 12 (overview) | 64×64 px | 300 m | 4 | ~16 KB |
| 13 (normal)   | 128×128 px | 300 m | 12 | ~192 KB |
| 15 (detail)   | 128×128 px | 150 m | 6 | ~96 KB |

Total bundle ≈ 304 KB. The watch decodes **one zoom level at a time**
(controlled by `_activeOsmZoom`, default 13).

**Zoom switching.** Zoom levels are **discovered from the bundle itself**:
`loadBundle()` calls `scanAvailableZooms()`, which collects the sorted distinct
zooms present in the tile entries into `_availableZooms` and sets the default
`_activeOsmZoom` to the available zoom nearest to 13. `checkZoomSwitch()` maps
`_zoomFactor` to one of them:

| `_zoomFactor` range | `_activeOsmZoom` |
|---|---|
| < 0.5 | lowest available (overview) |
| 0.5 – 3.0 | nearest to 13 (normal, default) |
| ≥ 3.0 | highest available (detail) |

(With no bundle loaded the old fixed 12/13/15 mapping applies.) This makes
single-zoom or arbitrary-zoom bundles — e.g. exported from MapsCreator — render
and zoom correctly instead of matching zero entries against a hardcoded trio.

When the threshold is crossed, `_pendingZoomSwitch = true`. In the next
`onUpdate()` frame, `switchToActiveZoom()` reloads the blob from Storage,
calls `prepareDecode()` with the new filter, and decoding restarts. Old
`BufferedBitmap`s are freed by `clearDecodedTiles()` before the reload.

Peak RAM during zoom switch: ~304 KB blob + up to ~192 KB new bitmaps ≈ 496 KB
(comfortably under the ~678 KB budget).

**Backwards compatibility.** Old single-zoom bundles (z13 only) load correctly:
`scanAvailableZooms` yields `[13]`, so every `_zoomFactor` maps to z13 — the
tile layer never goes empty; `drawScaledBitmap` handles the visual scaling.

**Bundle without a route.** A `.gmnd` may be sent standalone (MapsCreator →
garmiand → watch). `applyBundleViewportIfNeeded()` sets the viewport from the
bundle header bbox when no route has configured it, and `setBundleId()`
auto-switches `_mapMode` to TILES on a fresh bundle, so the map is viewable
immediately; `applyRoute()` later overrides the viewport when a route arrives.

## Auto map fetch (watch-initiated refresh while moving)

When the user walks toward the edge of the cached bundle, the watch asks the
phone for a fresh one — no manual re-sync needed.

**Watch side** (`GarmiandApp.maybeAutoFetch`, gated by the `auto_fetch`
property, default on): every 5th GPS tick (~5 s) it runs a handful of float
compares — TILES mode active, bundle header present, no transfer/decode in
flight, position within the outer 25% of the bundle bbox (or outside), and
≥2 min since the last request. If all pass, it sends one small
`Communications.transmit` of `map_request {lat, lon}` and rests again. All
heavy work happens on the phone, so the CIQ watchdog never sees sustained CPU
load from this feature.

**Phone side** (`MapRequestResponder`, registered as a persistent watch
listener in `MainActivity`): on `map_request` it quantizes a multi-zoom bundle
around the point (`quantizeMultiZoom` with `bufferScale = 4.0` → ~1.2 km at
z13), uploads via HTTPS with BLE fallback, and announces `tile_session` as
usual. Requests are dropped while one is being served or if the point moved
<300 m from the previously served center (content-CRC bundle ids make
identical bundles a Storage cache hit on the watch anyway).

## Sizing budget

- 64×64 tile × 1 byte/pixel = 4 KB per tile; 128×128 = 16 KB.
- Multi-zoom bundle: up to 22 tiles ≈ 304 KB (see table above).
- `Application.Storage` on Fenix 7: per-value limit ~32 KB (silent OOM if exceeded).
  Blobs are split into 16 KB chunks (`b_<id>_0`, `b_<id>_1`, …).
  LRU manifest (`bm`) tracks up to 32 cached bundles; oldest evicted when full.
- Graphics RAM: `_decodedTiles` holds at most 12 × 16 KB = 192 KB of `BufferedBitmap`s
  for the active zoom level at steady state.
- HTTPS download: `makeWebRequest` response buffer is ~12–16 KB (base64 text).
  We download in 10 KB chunks via `GET /sessions/:id/chunk?offset=N&size=10240`,
  writing directly into a pre-allocated `ByteArray` buffer.
