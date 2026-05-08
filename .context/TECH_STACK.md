# Tech Stack

## Languages

- **Kotlin** — Android companion. JVM target compatible with the Gradle config in `android/app/build.gradle.kts`.
- **Monkey C** — Garmin watch app. Strict typing: every parameter, return type, and field is annotated (`as Lang.Float`, `as Lang.Array<Lang.Float>`, etc.). Type-related warnings are not tolerated.

## Android Side

- **Connect IQ Mobile SDK** — `connectiq-sdk.aar` from Garmin Developer Portal, dropped into `android/app/libs/` and pulled in via `implementation(fileTree(...))`.
- **NanoHTTPD** (`org.nanohttpd:nanohttpd:2.3.1`) — embedded HTTP server. Currently unused at runtime (see ADR-003); class lives in `map/MapTileServer.kt`.
- **AndroidX AppCompat** — for `AppCompatActivity`.
- Standard `XmlPullParser` for GPX parsing — no third-party GPX library.

## Watch Side

- **Connect IQ SDK 9.1.0** (or whichever is current under `%APPDATA%\Garmin\ConnectIQ\Sdks\`).
- Target device: `fenix7` (manifest `<iq:product id="fenix7"/>`). minApiLevel 3.3.0.
- Permissions in `garmin/manifest.xml`: `Positioning`, `Communications`. No `<iq:uses-domain>` — sideloaded development builds are not enforced.

## Conventions (non-negotiable)

- **Phone messages are native `Map<String, Any>`** sent via `IQApp.sendMessage()`. No JSON, no Base64. Monkey C has no JSON parser; the watch reads them as `Lang.Dictionary` directly. See `API_CONTRACTS.md`.
- **Dictionary keys are `String`, not `Symbol`.** On the watch use `dict["kind"]`, never `dict[:kind]`.
- **Route points on the watch are stored as parallel `Float[]` arrays** (`lats[]`, `lons[]`), not as an array of dictionaries. Heap on Fenix 7 is tight.
- **Logging on Android goes through `util/AppLog.kt`.** It tees to both `android.util.Log` and an in-app scrolling view. Do not call `Log.x` directly in new code in `garmin/`, `map/`, `protocol/`, `ui/`, `sync/` — call `AppLog.x` so it shows up on-device.
- **Watch logging is `System.println`**, but on physical hardware it is invisible — use the on-screen debug overlay in `NavigationView` for diagnostics that matter.
- **No comments restating what the code does.** Comments only when the *why* is non-obvious (a Connect IQ quirk, a Web Mercator subtlety, a workaround for GCM behavior).
