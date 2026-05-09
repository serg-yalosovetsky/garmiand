# Garmiand Bundle Server

Cloud broker for quantized map bundles. Phone uploads a binary `bundle.bin` (the
`GMND` envelope produced by `TileBundleSerializer` on Android), the server
returns a `sessionId` + `downloadUrl`, and the watch app fetches that URL via
`Communications.makeWebRequest()` (GCM proxies public HTTPS without issue, see
ADR-006).

## Quick start

```bash
cp .env.example .env          # adjust BACKEND_TOKEN at minimum
npm install
npm start
```

Server listens on `:3000` by default. Health probe: `GET /healthz`.

## API

### `POST /sessions`

Headers:
- `Authorization: Bearer <BACKEND_TOKEN>`
- `Content-Type: application/octet-stream`

Body: raw bundle bytes (must start with magic `GMND`).

Response 200:
```json
{
  "sessionId": "uuid",
  "downloadUrl": "https://host/sessions/uuid",
  "expiresAt": "ISO-8601",
  "size": 12345
}
```

### `GET /sessions/:id`

Returns `application/octet-stream` of the bundle. 404 if missing, 410 if
retention expired.

## Deploy

The Dockerfile produces a small Alpine image. Suitable hosts: Fly.io,
Hetzner with Caddy reverse proxy, Railway. Mount a persistent volume at
`/app/data` if you want bundles to survive restarts; otherwise rely on
the 7-day TTL and let pods come and go.

For local-only smoke tests, `ngrok http 3000` is enough — the watch only
needs *some* public HTTPS endpoint.

## Auth

v1 uses a single shared `BACKEND_TOKEN` baked into the Android APK via
BuildConfig. Per-user auth is a future iteration; for now we rely on
unguessable Session IDs (UUIDv4) on the read side and a shared bearer
on the write side.
