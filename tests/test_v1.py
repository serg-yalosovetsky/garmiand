from app_v1.gpx_import import import_gpx
from app_v1.phone import PhoneCompanionApp
from app_v1.watch import MockWatchApp


def test_gpx_import_and_sync_flow():
    route = import_gpx("tests/data/sample.gpx")
    assert len(route.points) == 3
    assert len(route.markers) >= 2

    watch = MockWatchApp(off_route_threshold_m=50)
    phone = PhoneCompanionApp(watch)
    responses = phone.sync_route(route, chunk_size=50)

    assert all(r.get("status") == "ack" for r in responses)
    assert watch.state.active_route is not None
    assert watch.state.active_route.route_id == route.route_id


def test_off_route_detection():
    route = import_gpx("tests/data/sample.gpx")
    watch = MockWatchApp(off_route_threshold_m=20)
    phone = PhoneCompanionApp(watch)
    phone.sync_route(route, chunk_size=50)

    near = watch.update_position(50.4501, 30.5234)
    far = watch.update_position(50.5001, 30.6234)

    assert near["off_route"] is False
    assert far["off_route"] is True
