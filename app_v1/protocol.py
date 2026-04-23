from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Any

from app_v1.models import RoutePackage


@dataclass
class Message:
    session_id: str
    kind: str
    chunk_index: int
    chunk_count: int
    payload: dict[str, Any]


def encode_route_package(route: RoutePackage, chunk_size: int = 512) -> list[Message]:
    raw = json.dumps(route.to_dict(), ensure_ascii=False).encode("utf-8")
    chunks = [raw[i : i + chunk_size] for i in range(0, len(raw), chunk_size)]
    session_id = str(uuid.uuid4())

    messages: list[Message] = [
        Message(
            session_id=session_id,
            kind="sync_start",
            chunk_index=0,
            chunk_count=1,
            payload={"route_id": route.route_id, "name": route.name},
        )
    ]

    for idx, chunk in enumerate(chunks):
        messages.append(
            Message(
                session_id=session_id,
                kind="route_chunk",
                chunk_index=idx,
                chunk_count=len(chunks),
                payload={"data": chunk.decode("latin1")},
            )
        )

    messages.append(
        Message(
            session_id=session_id,
            kind="sync_finish",
            chunk_index=0,
            chunk_count=1,
            payload={"route_id": route.route_id},
        )
    )
    return messages


def decode_chunks(chunk_messages: list[Message]) -> RoutePackage:
    data = b"".join(msg.payload["data"].encode("latin1") for msg in chunk_messages)
    payload = json.loads(data.decode("utf-8"))
    return RoutePackage.from_dict(payload)
