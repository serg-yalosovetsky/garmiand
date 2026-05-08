# Connect IQ Notes

Hard-won facts about Connect IQ, Garmin Connect Mobile (GCM), and the Fenix 7. Read this before changing anything that crosses the BLE boundary.

## The proxy model

The watch has no IP stack. When watch code calls `Communications.makeImageRequest(url, ...)` or `Communications.makeWebRequest(url, ...)`, the call is forwarded over BLE to GCM running on the phone. **GCM makes the actual HTTP(S) request**, processes the image (resize, dither), and ships bytes back to the watch.

Implications:
- Network reachability is a property of the phone, not the watch.
- HTTPS cert validation is done by GCM, not by us.
- There is no streaming — the response is materialized in full before the watch sees a single byte.

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
