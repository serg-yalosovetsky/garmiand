from __future__ import annotations

from app_v1.models import RoutePackage
from app_v1.protocol import encode_route_package
from app_v1.watch import MockWatchApp


class PhoneCompanionApp:
    def __init__(self, watch: MockWatchApp) -> None:
        self.watch = watch

    def sync_route(self, route: RoutePackage, chunk_size: int = 512) -> list[dict[str, str]]:
        messages = encode_route_package(route, chunk_size=chunk_size)
        responses: list[dict[str, str]] = []

        for msg in messages:
            ack = self.watch.receive(msg)
            responses.append(ack)
            if ack.get("status") != "ack":
                break

        return responses
