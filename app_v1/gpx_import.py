from __future__ import annotations

import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

from app_v1.models import Marker, RoutePackage, RoutePoint


GPX_NS = {"gpx": "http://www.topografix.com/GPX/1/1"}


def import_gpx(path: str | Path, route_name: str | None = None) -> RoutePackage:
    root = ET.parse(path).getroot()

    track_points: list[RoutePoint] = []
    for node in root.findall(".//gpx:trkpt", GPX_NS):
        lat = float(node.attrib["lat"])
        lon = float(node.attrib["lon"])
        track_points.append(RoutePoint(lat=lat, lon=lon))

    markers: list[Marker] = []
    for idx, node in enumerate(root.findall(".//gpx:wpt", GPX_NS), start=1):
        lat = float(node.attrib["lat"])
        lon = float(node.attrib["lon"])
        title = node.findtext("gpx:name", default=f"Marker {idx}", namespaces=GPX_NS)
        markers.append(Marker(marker_id=f"wpt-{idx}", lat=lat, lon=lon, title=title))

    if track_points:
        markers = [
            Marker("start", track_points[0].lat, track_points[0].lon, "Start"),
            *markers,
            Marker("finish", track_points[-1].lat, track_points[-1].lon, "Finish"),
        ]

    return RoutePackage(
        route_id=str(uuid.uuid4()),
        name=route_name or Path(path).stem,
        points=track_points,
        markers=markers,
    )
