from __future__ import annotations

import base64
import json
import uuid
from typing import Any

from app_v1.models import RoutePackage


VERSION = 1


def encode_route_envelopes(route: RoutePackage, chunk_size: int = 120) -> list[dict[str, Any]]:
    raw = json.dumps(route.to_dict(), ensure_ascii=False).encode("utf-8")
    chunks = [raw[i : i + chunk_size] for i in range(0, len(raw), chunk_size)]
    session_id = str(uuid.uuid4())

    messages: list[dict[str, Any]] = [
        {
            "v": VERSION,
            "kind": "sync_start",
            "session_id": session_id,
            "route_id": route.route_id,
            "route_name": route.name,
        }
    ]

    for idx, chunk in enumerate(chunks):
        messages.append(
            {
                "v": VERSION,
                "kind": "route_chunk",
                "session_id": session_id,
                "route_id": route.route_id,
                "chunk_index": idx,
                "chunk_count": len(chunks),
                "payload_b64": base64.b64encode(chunk).decode("ascii"),
            }
        )

    messages.append(
        {
            "v": VERSION,
            "kind": "sync_finish",
            "session_id": session_id,
            "route_id": route.route_id,
        }
    )

    return messages


def decode_route_envelopes(messages: list[dict[str, Any]]) -> dict[str, Any]:
    chunks = [m for m in messages if m.get("kind") == "route_chunk"]
    chunks.sort(key=lambda item: item["chunk_index"])
    data = b"".join(base64.b64decode(m["payload_b64"]) for m in chunks)
    return json.loads(data.decode("utf-8"))
