from __future__ import annotations

import argparse

from app_v1.gpx_import import import_gpx
from app_v1.phone import PhoneCompanionApp
from app_v1.watch import MockWatchApp


def main() -> None:
    parser = argparse.ArgumentParser(description="V1 route sync demo (phone -> watch)")
    parser.add_argument("gpx", help="Path to GPX file")
    parser.add_argument("--lat", type=float, help="Simulated current latitude")
    parser.add_argument("--lon", type=float, help="Simulated current longitude")
    args = parser.parse_args()

    route = import_gpx(args.gpx)

    watch = MockWatchApp()
    phone = PhoneCompanionApp(watch)

    responses = phone.sync_route(route)
    print(f"Synced route '{route.name}' with {len(route.points)} points and {len(route.markers)} markers")
    print(f"ACK count: {len([r for r in responses if r.get('status') == 'ack'])}")

    if args.lat is not None and args.lon is not None:
        nav = watch.update_position(args.lat, args.lon)
        print(f"Distance to route: {nav['distance_m']} m; off_route={nav['off_route']}")


if __name__ == "__main__":
    main()
