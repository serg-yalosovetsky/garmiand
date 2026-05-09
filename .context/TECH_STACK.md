# Tech Stack

## Languages

- **Kotlin** — Android companion. JVM target compatible with the Gradle config in `android/app/build.gradle.kts`.
- **Monkey C** — Garmin watch app. Strict typing: every parameter, return type, and field is annotated (`as Lang.Float`, `as Lang.Array<Lang.Float>`, etc.). Type-related warnings are not tolerated.

## Android Side

- **Connect IQ Mobile SDK 2.4.0** — `com.garmin.connectiq:ciq-companion-app-sdk:2.4.0@aar` from Maven Central. No manual AAR drop required.
- **AndroidX AppCompat + Material** — for `AppCompatActivity` and `SwitchCompat`.
- **`org.json`** (built into Android) — used in `MapBundleUploader` for parsing the backend response.
- **HttpURLConnection** — used by `TileQuantizer` for tile fetches and `MapBundleUploader` for bundle uploads. No third-party HTTP client.
- Standard `XmlPullParser` for GPX parsing — no third-party GPX library.

## Backend

- **Node.js 20+ / Express 4** — under `server/`. Tiny REST API, no database, single-binary docker image. See [BACKEND.md](BACKEND.md).

## Watch Side

- **Connect IQ SDK 9.1.0** (or whichever is current under `%APPDATA%\Garmin\ConnectIQ\Sdks\`).
- Target device: `fenix7` (manifest `<iq:product id="fenix7"/>`). minApiLevel 3.3.0.
- Permissions in `garmin/manifest.xml`: `Positioning`, `Communications`, `Map`. (The last is required for `WatchUi.MapView`.) No `<iq:uses-domain>` — sideloaded development builds are not enforced.

## Conventions (non-negotiable)

- **Phone messages are native `Map<String, Any>`** sent via `IQApp.sendMessage()`. No JSON, no Base64. Monkey C has no JSON parser; the watch reads them as `Lang.Dictionary` directly. See `API_CONTRACTS.md`.
- **Dictionary keys are `String`, not `Symbol`.** On the watch use `dict["kind"]`, never `dict[:kind]`.
- **Route points on the watch are stored as parallel `Float[]` arrays** (`lats[]`, `lons[]`), not as an array of dictionaries. Heap on Fenix 7 is tight.
- **Logging on Android goes through `util/AppLog.kt`.** It tees to both `android.util.Log` and an in-app scrolling view. Do not call `Log.x` directly in new code in `garmin/`, `map/`, `protocol/`, `ui/`, `sync/` — call `AppLog.x` so it shows up on-device.
- **Watch logging is `System.println`**, but on physical hardware it is invisible — use the on-screen debug overlay in `NavigationView` for diagnostics that matter.
- **No comments restating what the code does.** Comments only when the *why* is non-obvious (a Connect IQ quirk, a Web Mercator subtlety, a workaround for GCM behavior).
