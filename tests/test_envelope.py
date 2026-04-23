from app_v1.envelope import decode_route_envelopes, encode_route_envelopes
from app_v1.gpx_import import import_gpx


def test_envelope_keys_and_order():
    route = import_gpx("tests/data/sample.gpx")
    messages = encode_route_envelopes(route, chunk_size=40)

    assert messages[0]["kind"] == "sync_start"
    assert messages[-1]["kind"] == "sync_finish"

    route_chunks = [m for m in messages if m["kind"] == "route_chunk"]
    assert route_chunks

    for idx, item in enumerate(route_chunks):
        assert item["v"] == 1
        assert item["session_id"] == messages[0]["session_id"]
        assert item["route_id"] == route.route_id
        assert item["chunk_index"] == idx
        assert item["chunk_count"] == len(route_chunks)
        assert isinstance(item["payload_b64"], str)


def test_envelope_roundtrip_decode():
    route = import_gpx("tests/data/sample.gpx")
    messages = encode_route_envelopes(route, chunk_size=40)
    payload = decode_route_envelopes(messages)

    assert payload["route_id"] == route.route_id
    assert payload["name"] == route.name
    assert len(payload["points"]) == len(route.points)
    assert len(payload["markers"]) == len(route.markers)
