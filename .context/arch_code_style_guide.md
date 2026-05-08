# Code Style Guide

## Kotlin (Android side)

- **Package layout** mirrors responsibility: `domain/`, `protocol/`, `osmand/`, `garmin/`, `map/`, `sync/`, `ui/`, `util/`. Don't introduce a new top-level package without a strong reason.
- **Logging is `AppLog`, not `Log`.** `AppLog.{i,w,e,d}(TAG, msg)` mirrors to logcat *and* to the on-screen panel. Direct `Log.x` is a regression.
- **`TAG`** is a top-level `private const val TAG = "..."` per file. Match the class name.
- **Sealed message types** for protocol messages: `SyncMessage` is `sealed interface`. New message kinds add a `data class` and a branch in `SyncMessageSerializer.toMap`.
- **No JSON in the Connect IQ path.** Native maps only. Keys live as `const val` in `PhoneMessageEnvelope`. Adding a key without registering it there is a bug — search-and-replace will miss the literal.
- **No try/catch swallowing.** If you catch, log via `AppLog.e(TAG, msg, e)` and surface a meaningful state to the UI.
- **No comments restating code.** Comment only when the *why* is non-obvious (a Connect IQ quirk, a Web Mercator subtlety, a workaround for GCM behavior). Knowing the reason is the only thing that helps the reader six months from now.

## Monkey C (watch side)

- **Type annotations everywhere.** Every parameter, return type, and field. No `as Any`, no inferred. The compiler emits warnings without them, and we treat warnings as failures.
- **Strings as keys** when reading dictionaries from phone messages — `dict["kind"]`, never `dict[:kind]`.
- **Cast numerics explicitly.** `(dict["x"] as Lang.Numeric).toFloat()` or `.toNumber()`. Connect IQ does not auto-coerce.
- **Float not Double.** Watch APIs use `Float`. Storage in `RouteData` is `Lang.Array<Lang.Float>`.
- **No new dictionary-of-points containers.** See ADR-002.
- **No `System.println` cleanup before review.** Keep them — they help in the simulator. They're invisible on hardware so they don't pollute anything.
- **Diagnostics that must be visible on hardware go on screen.** Add a banner in `NavigationView`, don't expect to read logs.

## Tests

- Tests for protocol encoding live under `tests/` (Python prototype) and Android JUnit. Add Android-side tests for new `SyncMessage` types — at minimum a round-trip through `SyncMessageSerializer.toMap` asserting required keys are present.
- No tests for Monkey C today. The simulator + on-device check is the loop. If a Monkey C unit-test framework lands, add one for `NavigationCalculator` first (haversine + nearest-point are pure).

## File-by-file etiquette

- `GarmiandApp.mc` is the routing brain. New `kind`s of phone messages get a dispatch branch here and a tested handler. Keep handlers small — push logic into `RouteData` or `NavigationCalculator`.
- `NavigationView.mc` owns drawing. No I/O, no message handling.
- `NavigationDelegate.mc` owns input. No drawing, no message handling.
- `MainActivity.kt` is allowed to be a bit of a glue layer, but new logic should land in a class under `sync/` or `garmin/`.
