from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any


@dataclass
class RoutePoint:
    lat: float
    lon: float


@dataclass
class Marker:
    marker_id: str
    lat: float
    lon: float
    title: str


@dataclass
class RoutePackage:
    route_id: str
    name: str
    points: list[RoutePoint]
    markers: list[Marker]

    def to_dict(self) -> dict[str, Any]:
        return {
            "route_id": self.route_id,
            "name": self.name,
            "points": [asdict(p) for p in self.points],
            "markers": [asdict(m) for m in self.markers],
        }

    @staticmethod
    def from_dict(payload: dict[str, Any]) -> "RoutePackage":
        return RoutePackage(
            route_id=payload["route_id"],
            name=payload["name"],
            points=[RoutePoint(**p) for p in payload["points"]],
            markers=[Marker(**m) for m in payload["markers"]],
        )
