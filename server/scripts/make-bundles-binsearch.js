// Generate a series of valid GMND bundles of varying total sizes for
// binary-searching the makeWebRequest response buffer limit on the watch.
// Each bundle has the standard 216-byte header+palette and is then padded
// with zero-filled "tile pixel data" (no tile entries, so the watch decoder
// just reads tiles=0 and ignores the trailing bytes).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(__dirname, '..', 'data');

const SIZES_KB = [1, 4, 8, 16, 24, 32, 40, 48, 56, 64];

fs.mkdirSync(DATA_DIR, { recursive: true });

function pad(n, w) {
  return String(n).padStart(w, '0');
}

const written = [];
for (const kb of SIZES_KB) {
  const total = Math.max(216, kb * 1024);
  const buf = Buffer.alloc(total);
  buf.write('GMND', 0, 4, 'ascii');
  buf.writeUInt8(1, 4);
  buf.writeUInt8(64, 5);
  buf.writeUInt16BE(0, 6);
  buf.writeFloatBE(50.45, 8);
  buf.writeFloatBE(50.46, 12);
  buf.writeFloatBE(30.52, 16);
  buf.writeFloatBE(30.54, 20);
  for (let i = 0; i < 64; i++) {
    buf.writeUInt8((i * 4) & 0xff, 24 + i * 3);
    buf.writeUInt8((i * 4) & 0xff, 24 + i * 3 + 1);
    buf.writeUInt8((i * 4) & 0xff, 24 + i * 3 + 2);
  }
  // remaining bytes already zero from Buffer.alloc — fine.

  const id = `00000000-0000-0000-0000-${pad(kb, 12)}`;
  const out = path.join(DATA_DIR, `${id}.bin`);
  fs.writeFileSync(out, buf);
  const b64 = Math.ceil(total / 3) * 4;
  written.push({ kb, total, b64, id });
  console.log(`  ${pad(kb, 2)} KB raw=${total}  base64≈${b64}  id=${id}`);
}

const PUBLIC_URL = process.env.PUBLIC_URL ?? 'https://71b1-103-167-234-246.ngrok-free.app';
const msgsDir = path.join(__dirname, '..', '..', 'simulator-msgs');
fs.mkdirSync(msgsDir, { recursive: true });

for (const w of written) {
  const file = path.join(msgsDir, `tile-session-${pad(w.kb, 2)}kb.json`);
  fs.writeFileSync(file, JSON.stringify({
    kind: 'tile_session',
    bundle_id: w.id,
    download_url: `${PUBLIC_URL}/sessions/${w.id}`,
  }, null, 2) + '\n');
}

console.log(`\nWrote ${written.length} bundles to ${DATA_DIR}`);
console.log(`Wrote ${written.length} tile-session JSONs to ${msgsDir}`);
