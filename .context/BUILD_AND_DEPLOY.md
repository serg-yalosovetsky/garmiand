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

```
monkeydo garmiand.prg fenix7
```

Use the simulator's `Phone → Send Message` to manually post a `route_full` (see `API_CONTRACTS.md`). Use `Settings → Set Position` to test GPS handling — note that the position-event callback can be flaky in the sim (we have a 1 Hz timer poll fallback for this exact reason).

## Android companion (APK)

### Prerequisites

- Android Studio. There is **no Gradle wrapper** in the project (`./gradlew` does not exist) — Android Studio's bundled Gradle is required.
- The Connect IQ Mobile SDK AAR (`connectiq-sdk.aar`) downloaded from Garmin Developer Portal and dropped into `android/app/libs/`.

### Build

`Build → Build Bundle(s) / APK(s) → Build APK(s)` in Android Studio.

### Install / iterate

- Connected device with USB debugging or ADB-over-Wi-Fi: `Run` from Android Studio (or `adb install -r path/to/app-debug.apk`).
- Inspect logs: the in-app log panel surfaces everything from `AppLog`. For raw `logcat`:
  ```powershell
  $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
  & $adb logcat -v time MainActivity:I MapTileServer:I TileComposer:* ConnectIQCompanion:* *:S
  ```
- Logcat is duplicative with the in-app panel today; the panel is preferred for screenshots.

## End-to-end smoke test

1. Sideload `garmiand.prg`.
2. Install APK.
3. Open Garmin Connect Mobile, confirm the Fenix 7 shows `Connected`.
4. Open the Android app — wait for `Garmin connected` in the status row.
5. Open the watch app on the Fenix.
6. Tap **Import GPX**, pick `tests/data/sample.gpx` (or any small `.gpx`).
7. Tap **Send**. Watch the in-app log:
   - `send -> sync_start` … `ack sync_start status=SUCCESS` (×4)
   - `Sending map_url tile=z…` → `ack map_url status=SUCCESS`
8. On the watch: route name in the top band, polyline, markers, optional map background. The yellow bottom-banner shows the map fetch status.
