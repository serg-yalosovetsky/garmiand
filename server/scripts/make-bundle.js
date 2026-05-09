// Generates one GMND-valid bundle of given size in KB, writes to data dir
// and emits a matching tile_session JSON in simulator-msgs/.
// Usage: node scripts/make-bundle.js <KB>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(__dirname, '..', 'data');
const MSGS_DIR = path.join(__dirname, '..', '..', 'simulator-msgs');
const PUBLIC_URL = process.env.PUBLIC_URL ?? 'https://71b1-103-167-234-246.ngrok-free.app';

const kb = parseInt(process.argv[2] ?? '32', 10);
if (!Number.isFinite(kb) || kb < 1) {
  console.error('Usage: node scripts/make-bundle.js <KB>');
  process.exit(1);
}

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

const id = `00000000-0000-0000-0000-${String(kb).padStart(12, '0')}`;
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(MSGS_DIR, { recursive: true });
fs.writeFileSync(path.join(DATA_DIR, `${id}.bin`), buf);
const msg = {
  kind: 'tile_session',
  bundle_id: id,
  download_url: `${PUBLIC_URL}/sessions/${id}`,
};
const msgFile = path.join(MSGS_DIR, `tile-session-${String(kb).padStart(2, '0')}kb.json`);
fs.writeFileSync(msgFile, JSON.stringify(msg, null, 2) + '\n');

const b64 = Math.ceil(total / 3) * 4;
console.log(`bundle: ${total} bytes (raw)  ≈${b64} bytes (base64)`);
console.log(`id:     ${id}`);
console.log(`json:   ${msgFile}`);
console.log('\nPaste into Simulation -> Phone App Message:');
console.log(JSON.stringify(msg));
