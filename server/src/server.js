import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.PORT ?? '3000', 10);
const TOKEN = process.env.BACKEND_TOKEN ?? 'dev-token-change-me';
const DATA_DIR = process.env.DATA_DIR ?? path.join(__dirname, '..', 'data');
const RETENTION_DAYS = parseInt(process.env.RETENTION_DAYS ?? '7', 10);
const PUBLIC_URL = (process.env.PUBLIC_URL ?? `http://localhost:${PORT}`).replace(/\/+$/, '');
const MAX_BUNDLE_BYTES = parseInt(process.env.MAX_BUNDLE_BYTES ?? `${4 * 1024 * 1024}`, 10);

fs.mkdirSync(DATA_DIR, { recursive: true });

const tokFingerprint = TOKEN.length >= 6
  ? `${TOKEN.slice(0, 3)}…${TOKEN.slice(-3)} (len=${TOKEN.length})`
  : `(len=${TOKEN.length})`;

const app = express();

app.use((req, res, next) => {
  const t = new Date().toISOString();
  const ip = req.headers['x-forwarded-for'] ?? req.socket.remoteAddress ?? '?';
  const ua = req.headers['user-agent'] ?? '-';
  const auth = req.headers['authorization']
    ? `Bearer …${String(req.headers['authorization']).slice(-4)}`
    : '(none)';
  const cl = req.headers['content-length'] ?? '-';
  console.log(`[${t}] → ${req.method} ${req.url} ip=${ip} ua="${ua}" auth=${auth} cl=${cl}`);
  const started = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - started;
    const sent = res.getHeader('content-length') ?? '-';
    console.log(`[${new Date().toISOString()}] ← ${req.method} ${req.url} ${res.statusCode} ${ms}ms bytes=${sent}`);
  });
  next();
});

app.get('/healthz', (_req, res) => {
  res.type('text/plain').send('ok');
});

app.post(
  '/sessions',
  express.raw({ type: 'application/octet-stream', limit: MAX_BUNDLE_BYTES }),
  (req, res) => {
    const auth = req.header('authorization') ?? '';
    if (auth !== `Bearer ${TOKEN}`) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
      return res.status(400).json({ error: 'empty body' });
    }
    if (req.body.length < 8 || req.body.subarray(0, 4).toString('ascii') !== 'GMND') {
      return res.status(400).json({ error: 'bad magic' });
    }

    const sessionId = crypto.randomUUID();
    const filePath = path.join(DATA_DIR, `${sessionId}.bin`);
    fs.writeFileSync(filePath, req.body);
    console.log(`[bundle-server] stored sessionId=${sessionId} bytes=${req.body.length}`);

    const expiresAt = new Date(Date.now() + RETENTION_DAYS * 24 * 3600 * 1000).toISOString();
    res.json({
      sessionId,
      downloadUrl: `${PUBLIC_URL}/sessions/${sessionId}`,
      expiresAt,
      size: req.body.length,
    });
  }
);

// GET /sessions/:id — returns the bundle as **base64 plain text**.
// Connect IQ's Communications.makeWebRequest() only supports text/JSON
// response types, so the watch decodes base64 via StringUtil.convertEncodedString.
// (See garmin/source/GarmiandApp.mc → handleTileSession.)
app.get('/sessions/:id', (req, res) => {
  const id = req.params.id;
  if (!/^[a-f0-9-]{32,40}$/i.test(id)) {
    return res.status(400).json({ error: 'bad id' });
  }
  const filePath = path.join(DATA_DIR, `${id}.bin`);
  fs.readFile(filePath, (err, buf) => {
    if (err) {
      return res.status(404).json({ error: 'not found' });
    }
    const ageMs = Date.now() - fs.statSync(filePath).mtimeMs;
    if (ageMs > RETENTION_DAYS * 24 * 3600 * 1000) {
      fs.unlink(filePath, () => {});
      return res.status(410).json({ error: 'expired' });
    }
    res.type('text/plain');
    res.send(buf.toString('base64'));
  });
});

setInterval(() => {
  fs.readdir(DATA_DIR, (err, files) => {
    if (err) return;
    const cutoff = Date.now() - RETENTION_DAYS * 24 * 3600 * 1000;
    for (const file of files) {
      if (!file.endsWith('.bin')) continue;
      const filePath = path.join(DATA_DIR, file);
      fs.stat(filePath, (sErr, stat) => {
        if (sErr) return;
        if (stat.mtimeMs < cutoff) fs.unlink(filePath, () => {});
      });
    }
  });
}, 60 * 60 * 1000).unref();

app.listen(PORT, () => {
  console.log(`[bundle-server] listening on :${PORT} dataDir=${DATA_DIR} retention=${RETENTION_DAYS}d`);
  console.log(`[bundle-server] token=${tokFingerprint} publicUrl=${PUBLIC_URL}`);
});
