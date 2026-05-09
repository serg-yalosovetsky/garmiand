# Backend

A tiny Node.js + Express service that brokers quantized map bundles between
the Android companion (uploader) and the watch (downloader). Lives in
[`server/`](../server/).

The transport architecture is in [ADR-006](ADR_LOG.md#adr-006-hybrid-tile-delivery-https-via-cloud-broker--ble-direct);
this doc is operational.

## Endpoints

### `POST /sessions`

| | |
|---|---|
| Auth | `Authorization: Bearer <BACKEND_TOKEN>` |
| Content-Type | `application/octet-stream` |
| Body | The raw `GMND` bundle (must start with magic bytes `0x47 0x4D 0x4E 0x44`). |

Response 200:
```json
{
  "sessionId": "uuid-v4",
  "downloadUrl": "<PUBLIC_URL>/sessions/<uuid>",
  "expiresAt": "ISO-8601",
  "size": 12345
}
```

Errors:
- `400 {"error":"empty body"}` — body missing or zero-length
- `400 {"error":"bad magic"}` — body doesn't start with `GMND` (cheap sanity check; we don't fully validate the format on the server)
- `401 {"error":"unauthorized"}` — bearer token mismatch
- `413 Payload Too Large` — exceeds `MAX_BUNDLE_BYTES` (default 4 MiB)

### `GET /sessions/:id`

Returns `text/plain` body containing the bundle **base64-encoded**.

Why text instead of `application/octet-stream`: Connect IQ's
`Communications.makeWebRequest()` only delivers strings or parsed JSON to the
watch. Streaming bytes into a `BitmapResource` is possible (`makeImageRequest`)
but we want raw bytes, not a decoded image. Base64 over text/plain is the
narrowest workaround that keeps the wire-format unified.

Errors:
- `400 {"error":"bad id"}` — id doesn't look like a UUID
- `404 {"error":"not found"}` — file missing
- `410 {"error":"expired"}` — file older than `RETENTION_DAYS`

### `GET /healthz`

Returns `text/plain` `ok` for liveness probes.

## Storage

Each upload is written to `${DATA_DIR}/<sessionId>.bin`. A one-hour cleanup
loop deletes files older than `RETENTION_DAYS`. For production, mount a
persistent volume at `DATA_DIR` if you care about bundles surviving a
restart; otherwise rely on the TTL and let the orchestrator come and go.

## Auth model (v1)

A single `BACKEND_TOKEN` shared between server and Android `BuildConfig`. It
gates uploads only — anyone with a `sessionId` can download. UUIDv4 is
unguessable in any practical sense, so this is acceptable for v1. Per-user
auth is a future iteration and would replace the bearer with a JWT.

## Deploying

The provided `Dockerfile` builds a 50 MB Alpine image. Suitable hosts:

- **Fly.io** — `fly launch` from `server/`, set `BACKEND_TOKEN` and
  `PUBLIC_URL` as secrets, attach a 1 GB volume at `/app/data` for retention.
- **Hetzner / a VPS** — `docker run` behind Caddy or Traefik for automatic
  Let's Encrypt. Caddy handles TLS, the container runs on `:3000`.
- **Local + ngrok** — fastest path for smoke tests. `npm start`,
  `ngrok http 3000`, drop the `https://*.ngrok-free.app` URL into
  `gradle.properties` as `garmiand.backendUrl`.

## Observability

The server prints one line on startup and one line per `POST /sessions` (via
Express default access log if you add one — the current implementation has
none). For production add `morgan` or similar.

## Failure modes worth checking

- **Token rotation** — change `BACKEND_TOKEN` server-side and rebuild the APK
  with the matching value in `gradle.properties`. Old APKs stop being able to
  upload (correct behavior).
- **Disk pressure** — if `DATA_DIR` fills, `POST /sessions` will start
  failing on `fs.writeFileSync`. The retention loop should keep this in check
  but does not actively respond to `ENOSPC`.
- **Connect IQ base64 cost** — fetching a 64 KB bundle as base64 means the
  watch reads ~85 KB of plain text. Within `makeWebRequest` limits but worth
  remembering if bundles ever grow.
