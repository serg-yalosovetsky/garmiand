# Connect IQ Phone Message Envelope (v1)

Единый формат сообщения между Android Companion и Garmin watch app.

## Поля envelope

| Key | Type | Обяз. | Описание |
|---|---|---|---|
| `v` | Int | да | Версия формата (`1`) |
| `kind` | String | да | `sync_start` / `route_chunk` / `sync_finish` |
| `session_id` | String | да | UUID сессии синка |
| `route_id` | String | да | ID маршрута |
| `route_name` | String | только для `sync_start` | Название маршрута |
| `chunk_index` | Int | только для `route_chunk` | Индекс чанка (0-based) |
| `chunk_count` | Int | только для `route_chunk` | Общее число чанков |
| `payload_b64` | String | только для `route_chunk` | Base64-кусок JSON маршрута |

## Пример: sync_start

```json
{
  "v": 1,
  "kind": "sync_start",
  "session_id": "7b93f398-6d85-4537-a70c-f338af5a67e9",
  "route_id": "demo-route-v1",
  "route_name": "Demo route"
}
```

## Пример: route_chunk

```json
{
  "v": 1,
  "kind": "route_chunk",
  "session_id": "7b93f398-6d85-4537-a70c-f338af5a67e9",
  "route_id": "demo-route-v1",
  "chunk_index": 0,
  "chunk_count": 3,
  "payload_b64": "eyJyb3V0ZUlkIjoiZGVtby1yb3V0ZS12MSIsLi4ufQ=="
}
```
