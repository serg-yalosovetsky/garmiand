# Build and Deploy

## Watch app (`.prg`)

### Prerequisites

- Connect IQ SDK installed (default Windows path: `%APPDATA%\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-<version>\bin\`).
- A `developer_key` (binary file). Already in the repo at `garmin/developer_key`.
- The SDK `bin/` on `PATH` is convenient but not required.

### Build (release, for device)

```powershell
$monkeyc = "$env:APPDATA\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-<version>\bin\monkeyc.bat"
& $monkeyc -d fenix7 -f garmin\monkey.jungle -o garmiand.prg -y garmin\developer_key --release
```

Or, with `bin/` on `PATH`:
```
monkeyc -d fenix7 -f garmin\monkey.jungle -o garmiand.prg -y garmin\developer_key --release
```

Output: `garmiand.prg` at the repo root, ~13 KB. `BUILD SUCCESSFUL` is the only acceptable end state.

### Sideload to Fenix 7

1. USB-cable the watch to the PC. It mounts as `GARMIN`.
2. Copy `garmiand.prg` → `GARMIN\APPS\` (overwriting any prior version).
3. Eject and unplug.
4. On the watch: `Hold UP` → `Activities & Apps` → `Add` → `Garmiand` → launch once.

### Run in the simulator

The output `.prg` is named after the app ID (same UUID as `manifest.xml`):

```powershell
# Build
$mc = "$env:APPDATA\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.1.0-2026-03-09-6a872a80b\bin\monkeyc.bat"
Set-Location G:\code\garmiand\garmin
& $mc -o 71DA4029287A447BBE86B83DC1588647.prg -f monkey.jungle -d fenix7 -y developer_key

# Run (simulator must already be open)
monkeydo G:\code\garmiand\garmin\71DA4029287A447BBE86B83DC1588647.prg fenix7
```

Use the simulator's `Phone → Send Message` to manually post a `route_full`
(see `API_CONTRACTS.md`) or a `tile_session` (see
`simulator-msgs/chunks/00-tile-session-local.json`). Use
`Settings → Set Position` for GPS testing.

**Simulator logs** stream to `monkeydo` stdout — the only way to read
`System.println` output without a physical device. The on-screen yellow debug
band mirrors critical messages for hardware testing.

## Android companion (APK)

### Prerequisites

- Android Studio. There is **no Gradle wrapper** in the project (`./gradlew` does not exist) — Android Studio's bundled Gradle is required.
- The Connect IQ Mobile SDK is fetched from Maven Central — no manual AAR drop needed. (Was `android/app/libs/` historically.)
- Optional but recommended: a backend reachable over HTTPS (see [BACKEND.md](BACKEND.md)). Without one, the "Cache map for offline" toggle silently falls back to BLE — slower but works.

### Build

Set the backend coordinates either in `gradle.properties`:
```
garmiand.backendUrl=https://your-host.example/api
garmiand.backendToken=<shared-with-server>
```
or via env (`GARMIAND_BACKEND_URL`, `GARMIAND_BACKEND_TOKEN`). Then in
Android Studio: `Build → Build Bundle(s) / APK(s) → Build APK(s)`.

### Install / iterate

- Connected device with USB debugging or ADB-over-Wi-Fi: `Run` from Android Studio (or `adb install -r path/to/app-debug.apk`).
- Inspect logs: the in-app log panel surfaces everything from `AppLog`. For raw `logcat`:
  ```powershell
  $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
  & $adb logcat -v time MainActivity:I TileQuantizer:I MapBundleUploader:I MapBundleBleSender:I ConnectIQCompanion:* *:S
  ```
- Logcat is duplicative with the in-app panel today; the panel is preferred for screenshots.

## Backend (cloud broker for HTTPS bundle delivery)

```bash
cd server
cp .env.example .env   # adjust BACKEND_TOKEN
npm install
npm start              # listens on :3000
```

For local smoke tests with a real watch, expose with `ngrok http 3000` and
plug the resulting `https://*.ngrok-free.app` URL into `gradle.properties` as
`garmiand.backendUrl`.

For production, the Dockerfile in `server/` produces a small Alpine image —
deploy on Fly.io / Hetzner / Railway with TLS in front. See
[BACKEND.md](BACKEND.md) for details.

## End-to-end smoke tests

### Test 1 — HTTPS path (online)

1. `cd server && npm start` (or have a deployed instance reachable).
2. Build and install APK with `garmiand.backendUrl` set correctly.
3. Sideload `garmiand.prg` to the Fenix 7.
4. Open Garmin Connect Mobile, confirm the Fenix 7 shows `Connected`.
5. Open the Android app — wait for `Garmin connected`.
6. Open the watch app on the Fenix.
7. Tap **Import GPX**, pick `tests/data/sample.gpx`.
8. Toggle **Cache map for offline** ON.
9. Tap **Send**. In the log, expect:
   - `send -> sync_start` … `ack ... status=SUCCESS` (×4)
   - `Quantizing tiles for bbox ...` → `Bundle ready: N tiles, MB`
   - `uploaded MB → <bundleId>`
   - `tile_session ack ok=true`
10. On the watch: route name + polyline + waypoints visible in NATIVE mode (default).
11. Press **SELECT** to cycle to TILES — the quantized OSM tile underlay should appear.

### Test 2 — BLE path (offline)

1. Put the phone in airplane mode (BT still on, mobile data + Wi-Fi off).
2. Tap **Send** with **Cache map** still on.
3. Expected log:
   - Route messages as in Test 1.
   - `BACKEND_URL` not configured / network down → `BLE chunk 1/N` … `N/N`
   - `BLE send complete bundleId=<id>`
4. Cycle to TILES on the watch — the same map appears.

### Test 3 — Field mode (cache survives offline)

1. Run Test 1 successfully.
2. Power off the phone, or remove it from BT range.
3. Open the watch app cold. TILES mode still renders the cached bundle from
   `Application.Storage`. Polyline overlays correctly. GPS-position dot
   updates as the user walks.

### Regressions to avoid

- Cycling SELECT in MapView's `MAP_MODE_BROWSE` shouldn't conflict with our
  mode-cycle. If users report it does, remap the toggle.
- `route_full` debug-path (Connect IQ simulator's `Phone → Send Message`)
  should keep working.
- `WATCH_APP_ID` ↔ `manifest.xml` id are coupled — never change one without
  the other.
