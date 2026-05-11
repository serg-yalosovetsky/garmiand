#!/usr/bin/env python3
"""
gen_bundle.py  — fetch OSM tiles for a route, quantize to 64-color GMND bundle,
write server/data/<uuid>.bin and update simulator-msgs JSON files.

Usage:
    python simulator-msgs/gen_bundle.py
"""

import io, math, struct, uuid, json, time, sys, os
import urllib.request
from PIL import Image

# ── Paths ──────────────────────────────────────────────────────────────────────
REPO_ROOT     = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SERVER_DATA   = os.path.join(REPO_ROOT, "server", "data")
MSGS_DIR      = os.path.join(REPO_ROOT, "simulator-msgs")
CHUNKS_DIR    = os.path.join(MSGS_DIR, "chunks")

# ── Route definition ───────────────────────────────────────────────────────────
# Winding ~600 m path in Kyiv near 50.505, 30.486.
ROUTE_NAME = "Kyiv winding test"
ROUTE_LATS = [
    50.5040, 50.5050, 50.5058, 50.5062,
    50.5060, 50.5052, 50.5047, 50.5044,
]
ROUTE_LONS = [
    30.4835, 30.4840, 30.4850, 30.4862,
    30.4875, 30.4882, 30.4874, 30.4888,
]

OUTPUT_SIZE   = 128
MAX_TILES     = 4   # keep bundle small (2×2 grid)
SERVER_BASE   = "http://127.0.0.1:3000"

# ── Palette ────────────────────────────────────────────────────────────────────
_LEVELS = [0, 85, 170, 255]

def _build_palette():
    pal = [None] * 64
    for r in range(4):
        for g in range(4):
            for b in range(4):
                pal[(r << 4) | (g << 2) | b] = (_LEVELS[r], _LEVELS[g], _LEVELS[b])
    return pal

PALETTE = _build_palette()

def _qch(v):
    if v < 42:  return 0
    if v < 127: return 1
    if v < 212: return 2
    return 3

def nearest_palette(r, g, b):
    return (_qch(r) << 4) | (_qch(g) << 2) | _qch(b)

# ── Web Mercator ───────────────────────────────────────────────────────────────
def ll_to_tile(lat, lon, zoom):
    n = 1 << zoom
    tx = int((lon + 180.0) / 360.0 * n)
    lr = math.radians(lat)
    ty = int((1.0 - math.log(math.tan(lr) + 1.0 / math.cos(lr)) / math.pi) / 2.0 * n)
    return tx, ty

def tile_nw_ll(tx, ty, zoom):
    n = 1 << zoom
    lon = tx / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * ty / n))))
    return lat, lon

def choose_zoom(lats, lons):
    min_lat, max_lat = min(lats), max(lats)
    min_lon, max_lon = min(lons), max(lons)
    for zoom in range(16, 0, -1):
        tx0, ty0 = ll_to_tile(max_lat, min_lon, zoom)
        tx1, ty1 = ll_to_tile(min_lat, max_lon, zoom)
        nx = tx1 - tx0 + 1
        ny = ty1 - ty0 + 1
        if nx * ny <= MAX_TILES:
            return zoom, tx0, ty0, tx1, ty1
    return 1, *ll_to_tile(max_lat, min_lon, 1), *ll_to_tile(min_lat, max_lon, 1)

# ── Tile fetch + quantize ──────────────────────────────────────────────────────
def fetch_tile(zoom, tx, ty):
    url = f"https://tile.openstreetmap.org/{zoom}/{tx}/{ty}.png"
    req = urllib.request.Request(url, headers={
        "User-Agent": "Garmiand/1.0 (simulator bundle generator)"
    })
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = resp.read()
    return Image.open(io.BytesIO(data)).convert("RGB")

def quantize_tile(img):
    img = img.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.LANCZOS)
    px  = img.load()
    out = bytearray(OUTPUT_SIZE * OUTPUT_SIZE)
    for col in range(OUTPUT_SIZE):
        for row in range(OUTPUT_SIZE):
            r, g, b = px[col, row]
            out[col * OUTPUT_SIZE + row] = nearest_palette(r, g, b)
    return bytes(out)

# ── GMND serializer ────────────────────────────────────────────────────────────
def write_gmnd(tiles, bbox):
    """
    tiles: list of (zoom, tx, ty, w, h, pixels_bytes)
    bbox:  (minLat, maxLat, minLon, maxLon)  — all float
    """
    tc = len(tiles)
    # 24-byte header
    blob  = b"GMND"
    blob += struct.pack(">BBH", 1, 64, tc)           # version, paletteSize, tileCount
    blob += struct.pack(">ffff", *bbox)               # minLat, maxLat, minLon, maxLon
    # palette: 64 × RGB888
    for (r, g, b) in PALETTE:
        blob += bytes([r, g, b])
    # tile entries (21 bytes each)
    base = 24 + 64 * 3 + tc * 21
    entries = bytearray()
    pixels  = bytearray()
    off = base
    for (zoom, tx, ty, w, h, px_bytes) in tiles:
        entries += struct.pack(">B", zoom)
        entries += struct.pack(">I", tx)
        entries += struct.pack(">I", ty)
        entries += struct.pack(">HH", w, h)
        entries += struct.pack(">II", off, len(px_bytes))
        pixels  += px_bytes
        off     += len(px_bytes)
    return blob + bytes(entries) + bytes(pixels)

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    os.makedirs(SERVER_DATA, exist_ok=True)
    os.makedirs(CHUNKS_DIR,  exist_ok=True)

    zoom, tx0, ty0, tx1, ty1 = choose_zoom(ROUTE_LATS, ROUTE_LONS)
    nx = tx1 - tx0 + 1
    ny = ty1 - ty0 + 1
    print(f"zoom={zoom}  tileX={tx0}..{tx1}  tileY={ty0}..{ty1}  grid={nx}×{ny}={nx*ny} tiles")

    tiles = []
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            print(f"  fetching z{zoom}/{tx}/{ty} ...", end=" ", flush=True)
            time.sleep(0.5)
            img = fetch_tile(zoom, tx, ty)
            px  = quantize_tile(img)
            tiles.append((zoom, tx, ty, OUTPUT_SIZE, OUTPUT_SIZE, px))
            print(f"{len(px)} B")

    top_lat,  left_lon  = tile_nw_ll(tx0,     ty0,     zoom)
    bot_lat,  right_lon = tile_nw_ll(tx1 + 1, ty1 + 1, zoom)
    bbox = (bot_lat, top_lat, left_lon, right_lon)

    blob = write_gmnd(tiles, bbox)
    print(f"\nbundle  {len(blob)} B  bbox lat=[{bot_lat:.5f}..{top_lat:.5f}] lon=[{left_lon:.5f}..{right_lon:.5f}]")

    bundle_id = str(uuid.uuid4())
    bin_path  = os.path.join(SERVER_DATA, f"{bundle_id}.bin")
    with open(bin_path, "wb") as f:
        f.write(blob)
    print(f"wrote   {bin_path}")

    # ── simulator-msgs/chunks/00-tile-session-local.json ──────────────────────
    session = {
        "kind":         "tile_session",
        "bundle_id":    bundle_id,
        "download_url": f"{SERVER_BASE}/sessions/{bundle_id}",
        "total_bytes":  len(blob),
    }
    session_path = os.path.join(CHUNKS_DIR, "00-tile-session-local.json")
    with open(session_path, "w") as f:
        json.dump(session, f, indent=2)
    print(f"wrote   {session_path}")

    # ── simulator-msgs/01-route-full.json ─────────────────────────────────────
    route = {
        "kind":       "route_full",
        "route_id":   "test-kyiv-1",
        "route_name": ROUTE_NAME,
        "lats":       ROUTE_LATS,
        "lons":       ROUTE_LONS,
        "markers": [
            {"id": "start",  "title": "Start",  "lat": ROUTE_LATS[0],  "lon": ROUTE_LONS[0]},
            {"id": "finish", "title": "Finish", "lat": ROUTE_LATS[-1], "lon": ROUTE_LONS[-1]},
        ],
    }
    route_path = os.path.join(MSGS_DIR, "01-route-full.json")
    with open(route_path, "w") as f:
        json.dump(route, f, indent=2)
    print(f"wrote   {route_path}")

    print(f"\nDone. bundle_id = {bundle_id}")
    print(f"Next:  cd server && npm start")
    print(f"       → send 01-route-full.json, then chunks/00-tile-session-local.json to simulator")

if __name__ == "__main__":
    main()
