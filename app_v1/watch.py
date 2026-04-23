from __future__ import annotations

from dataclasses import dataclass
from math import asin, cos, radians, sin, sqrt

from app_v1.models import RoutePackage, RoutePoint
from app_v1.protocol import Message, decode_chunks


@dataclass
class WatchState:
    active_route: RoutePackage | None = None
    off_route: bool = False


class MockWatchApp:
    def __init__(self, off_route_threshold_m: float = 40.0) -> None:
        self.state = WatchState()
        self._pending_chunks: list[Message] = []
        self.off_route_threshold_m = off_route_threshold_m

    def receive(self, message: Message) -> dict[str, str]:
        if message.kind == "sync_start":
            self._pending_chunks = []
            return {"status": "ack", "kind": "sync_start"}

        if message.kind == "route_chunk":
            self._pending_chunks.append(message)
            return {"status": "ack", "kind": "route_chunk", "index": str(message.chunk_index)}

        if message.kind == "sync_finish":
            self.state.active_route = decode_chunks(sorted(self._pending_chunks, key=lambda m: m.chunk_index))
            return {"status": "ack", "kind": "sync_finish", "route_id": message.payload["route_id"]}

        return {"status": "error", "reason": "unknown_message"}

    def update_position(self, lat: float, lon: float) -> dict[str, float | bool]:
        if not self.state.active_route or not self.state.active_route.points:
            return {"off_route": False, "distance_m": 0.0}

        current = RoutePoint(lat=lat, lon=lon)
        nearest = min(
            _haversine_m(current.lat, current.lon, pt.lat, pt.lon)
            for pt in self.state.active_route.points
        )
        self.state.off_route = nearest > self.off_route_threshold_m
        return {"off_route": self.state.off_route, "distance_m": round(nearest, 2)}


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return 2 * r * asin(sqrt(a))
