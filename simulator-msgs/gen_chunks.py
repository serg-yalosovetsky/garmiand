"""
Generate simulator tile_chunk/tile_session messages from a .bin bundle.

Usage:
    python gen_chunks.py <bundle.bin> [chunk_size_kb] [base_url]

    base_url  e.g. https://xxxx.ngrok-free.app  (default: http://127.0.0.1:3000)

Outputs:
    chunks/00-tile-session-local.json  — tile_session with base_url
    chunks/<NN>-tile-chunk-<i>.json    — one per BLE chunk (info only)

Each JSON can be pasted into Garmin Simulator -> Phone -> Send Message.
Note: the simulator cannot send raw ByteArray, so BLE chunks are for reference
only. Use the HTTPS path (00-tile-session-local.json) for simulator testing.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import uuid

CHUNK_SIZE_DEFAULT = 12 * 1024


def _write_json(path: str, data: object) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)


def _generate(bin_path: str, chunk_size: int, base_url: str) -> None:
    with open(bin_path, "rb") as fh:
        blob = fh.read()

    bundle_id = str(uuid.uuid4())
    session_id = str(uuid.uuid4())
    chunks = [blob[i : i + chunk_size] for i in range(0, len(blob), chunk_size)]
    total = len(chunks)

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chunks")
    os.makedirs(out_dir, exist_ok=True)

    session_msg = {
        "kind": "tile_session",
        "bundle_id": bundle_id,
        "download_url": f"{base_url}/sessions/{bundle_id}",
    }
    session_path = os.path.join(out_dir, "00-tile-session-local.json")
    _write_json(session_path, session_msg)
    print(f"[session] {session_path}")
    print(f"  bundle_id  = {bundle_id}")
    print(f"  copy bundle: cp \"{bin_path}\" server/data/{bundle_id}.bin")

    note = (
        "The simulator Send Message dialog does not support raw ByteArray. "
        "Use the Android app for BLE testing or the HTTPS path above."
    )
    for i, chunk in enumerate(chunks):
        msg = {
            "kind": "tile_chunk",
            "session_id": session_id,
            "bundle_id": bundle_id,
            "i": i,
            "n": total,
            "p_b64": base64.b64encode(chunk).decode(),
            "_note": note,
        }
        fname = os.path.join(out_dir, f"{i + 1:02d}-tile-chunk-{i}.json")
        _write_json(fname, msg)

    print(f"[chunks]  {total} chunk files written to {out_dir}/")
    print(f"  bundle={len(blob)}B  chunk_size={chunk_size}B")
    print()
    print("=== HTTPS path via simulator ===")
    print("1. Start server:  cd server && node src/server.js")
    print(f"2. Copy bundle:   cp \"{bin_path}\" server/data/{bundle_id}.bin")
    print("3. Simulator:     Phone -> Send Message -> paste 00-tile-session-local.json")
    print("4. monkeydo log:  'HTTPS 200' ... 'persist ok'")


def main() -> None:
    """Entry point."""
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    bin_path = sys.argv[1]
    chunk_size = int(sys.argv[2]) * 1024 if len(sys.argv) >= 3 else CHUNK_SIZE_DEFAULT
    base_url = sys.argv[3].rstrip("/") if len(sys.argv) >= 4 else "http://127.0.0.1:3000"
    _generate(bin_path, chunk_size, base_url)


if __name__ == "__main__":
    main()
