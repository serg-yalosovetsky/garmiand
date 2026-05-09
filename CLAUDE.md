# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

Transfers GPX routes from an Android phone to a Garmin Fenix 7 watch over Bluetooth (Connect IQ). The watch renders the route on top of a map background (Garmin TopoActive or custom raster tiles) with GPS position and off-route detection. A Node.js backend brokers map tile bundles when the phone has internet; BLE direct-chunking is the offline fallback.

## Build commands

### Watch app (Connect IQ / Monkey C)

```powershell
# Build
$mc = "$env:APPDATA\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.1.0-2026-03-09-6a872a80b\bin\monkeyc.bat"
Set-Location G:\code\garmiand\garmin
& $mc -o 71DA4029287A447BBE86B83DC1588647.prg -f monkey.jungle -d fenix7 -y developer_key

# Run in simulator (simulator must be open first)
monkeydo G:\code\garmiand\garmin\71DA4029287A447BBE86B83DC1588647.prg fenix7

# Release build (for sideload to device)
& $mc -d fenix7 -f garmin\monkey.jungle -o garmiand.prg -y garmin\developer_key --release
```

`System.println` output streams to `monkeydo` stdout — only way to read it without hardware.

### Android companion

Build via Android Studio only (no Gradle wrapper). Set backend coordinates in `gradle.properties`:
```
garmiand.backendUrl=https://your-host/api
garmiand.backendToken=<token>
```
Or via env `GARMIAND_BACKEND_URL` / `GARMIAND_BACKEND_TOKEN`. Empty `backendUrl` → BLE-only mode.

### Backend

```bash
cd server && cp .env.example .env  # set BACKEND_TOKEN, PUBLIC_URL
npm install && npm start            # listens on :3000
```

For watch simulator testing: `ngrok http 3000` and paste the URL into `gradle.properties`.

### Python prototype / tests

```bash
python main.py tests/data/sample.gpx --lat 50.4501 --lon 30.5234
pytest -q
```

## Architecture

Three runtime components:

**Android companion** (`android/app/src/main/java/com/garmiand/`)  
Imports GPX → sends route chunks → optionally quantizes and uploads a map bundle. Key flow: `MainActivity` → `RouteSyncOrchestrator` → `ConnectIQGarminCompanion` (wraps the Connect IQ Mobile SDK). Map bundle path: `TileQuantizer` (fetches OSM tiles, column-major 64-color quantization) → `TileBundleSerializer` (GMND binary) → `MapBundleUploader` (HTTPS) or `MapBundleBleSender` (BLE chunks). All observable events go through `util/AppLog` — never `Log.x` directly.

**Watch app** (`garmin/source/`)  
`GarmiandApp` is the routing brain (`AppBase`). `NavigationView extends WatchUi.MapView` owns all drawing. `NavigationDelegate` owns input. `TileDecoder` owns the GMND binary format. `BleChunkAssembler` owns BLE reassembly. `RouteData` stores route as parallel `Float[]` arrays (no dictionaries-of-points — heap is tight on Fenix 7).

**Backend** (`server/`)  
Thin Express broker. `POST /sessions` accepts a raw GMND blob (max 4 MiB), writes to disk, returns `{sessionId, downloadUrl}`. `GET /sessions/:id/chunk?offset=N&size=M` returns base64-encoded slices (watch downloads in 10 KB increments because `makeWebRequest` has a ~12–16 KB response buffer cap). Watch cannot reach phone-local IPs through GCM — needs a public HTTPS URL.

## Invariants that span multiple files

**WATCH_APP_ID ↔ manifest.xml id** — `ConnectIQGarminCompanion.kt:WATCH_APP_ID` and `garmin/manifest.xml` `<iq:application id="...">` must be the same UUID (`71DA4029287A447BBE86B83DC1588647`). Drift → "app not found".

**Palette is a shared constant** — `map/Palette.kt` (phone) and `garmin/source/TileDecoder.mc` (watch) must agree on the 64-color palette and `BUNDLE_VERSION`. Changing either invalidates all stored bundles. Bump `Palette.VERSION` and `TileDecoder.BUNDLE_VERSION` together.

**Protocol keys live in `PhoneMessageEnvelope.kt`** — all BLE message field names are `const val` there. Adding a key anywhere else means grep won't find it.

**`ensureBundleLoaded()` before `isComplete` guard** — in `NavigationView.onUpdate()`, the bundle-load check must execute before the `!_route.isComplete` early-return, or a tile_session message received before route sync completes will never trigger decode.

**No heavy work in HTTP/BLE callbacks** — watchdog budget in `onPhoneMessage` and `onBundleChunkResponse` is shorter than in `onUpdate`. Set a flag, do the work in `onUpdate`.

## Connect IQ hard limits

- **Storage**: per-value limit ~32 KB (silent OOM crash if exceeded, not `StorageFullException`). Blobs are stored as `b_<id>_0 … b_<id>_N` at 16 KB each via `TileDecoder.persist/load`.
- **makeWebRequest**: TEXT_PLAIN buffer cap ~12–16 KB. `HTTP_RESPONSE_CONTENT_TYPE_BYTE_ARRAY` does not exist. Fetch bundles in 10 KB slices.
- **Tile decode**: 128×128 tile = 16 384 pixels trips the watchdog even in `onUpdate`. Process **8 columns per frame** via `TileDecoder.fillTileColumns`. Hold the `BufferedBitmap` Dc open between frames.
- **`getBuffer()`** does not exist in SDK 9.1.0 / fenix7. All pixel writes go through the Dc API.
- **`new [N]b`** creates `Lang.ByteArray`; `[] as Lang.ByteArray` creates a regular `Lang.Array` (crashes on `.addAll()`).
- **Map permission**: `<iq:uses-permission id="Map"/>` is invalid and breaks the build. `MapView` works without it.
- **GPS registration**: must be in `AppBase.onStart`, not in sub-objects. Also poll `Position.getInfo()` with a 1 s `Timer` — simulator GPS callbacks are unreliable.
- **String keys in dictionaries**: `dict["kind"]` works on the watch; `dict[:kind]` does not.
- **GCM proxy**: only public HTTPS URLs work. `http://localhost:*` and LAN IPs are silently blocked.

## Code style

**Monkey C**: type-annotate every parameter, return type, and field. Cast numerics explicitly: `(dict["x"] as Lang.Numeric).toFloat()`. Never use `as Any` or inferred types — compiler warnings are treated as failures.

**Kotlin**: sealed interface for protocol messages (`SyncMessage`). New message kinds add a `data class` and a branch in `SyncMessageSerializer.toMap`. `AppLog.{i,w,e,d}(TAG, msg)` for all logging.

**Boundaries**: `NavigationView.mc` is drawing-only; `NavigationDelegate.mc` is input-only; `GarmiandApp.mc` dispatches messages and keeps handlers small. New sync logic goes in `sync/`, not in `MainActivity`.

## Context docs

`.context/` has load-bearing docs — read before changing anything cross-cutting:
- `ADR_LOG.md` — why parallel Float arrays, why our own backend, why column-by-column decode
- `API_CONTRACTS.md` — full BLE message schema
- `CONNECT_IQ_NOTES.md` — all hard-won SDK quirks
- `bug_fixes.md` — recurring failure modes and their fixes
- `CONFIGURATION.md` — all tunable constants and where they live
