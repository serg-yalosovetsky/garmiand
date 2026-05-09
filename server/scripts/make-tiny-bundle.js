// Builds a minimal valid GMND bundle (header + 64-color palette, 0 tiles)
// — exactly 216 bytes — and writes it to server/data/<uuid>.bin so we can
// test the HTTP fetch path under the makeWebRequest response buffer limit.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(__dirname, '..', 'data');
const TINY_ID = '11111111-1111-1111-1111-111111111111';

const buf = Buffer.alloc(216);
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

fs.mkdirSync(DATA_DIR, { recursive: true });
const out = path.join(DATA_DIR, `${TINY_ID}.bin`);
fs.writeFileSync(out, buf);
console.log(`Wrote ${out} (${buf.length} bytes)`);
console.log(`Bundle ID: ${TINY_ID}`);
