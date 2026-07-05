using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.System;

// On-wire format (must stay in sync with android/.../TileBundleSerializer.kt
// and server/src/server.js validation):
//
// offset  size  field
// 0       4     magic = "GMND"
// 4       1     version = 1
// 5       1     paletteSize (= 64 in v1)
// 6       2     tileCount (uint16 BE)
// 8       16    bbox (4 × float32 BE: minLat, maxLat, minLon, maxLon)
// 24      P*3   palette (P × RGB888, P = paletteSize)
// 24+P*3  T*21  tile entries
// ...           tile pixel arrays (column-major, 1 byte = 1 palette index 0..63)
//
// Each tile entry (21 bytes):
//   0     1   zoom
//   1     4   tileX (uint32 BE)
//   5     4   tileY (uint32 BE)
//   9     2   width (uint16 BE)
//   11    2   height (uint16 BE)
//   13    4   pixelOffset (uint32 BE, relative to blob start)
//   17    4   pixelLength (uint32 BE)

const BUNDLE_MAGIC_0 = 0x47; // 'G'
const BUNDLE_MAGIC_1 = 0x4D; // 'M'
const BUNDLE_MAGIC_2 = 0x4E; // 'N'
const BUNDLE_MAGIC_3 = 0x44; // 'D'
const BUNDLE_VERSION = 2;
const TILE_ENTRY_SIZE = 21;
const HEADER_FIXED_SIZE = 24;

class BundleHeader {
    var version as Lang.Number;
    var paletteSize as Lang.Number;
    var tileCount as Lang.Number;
    var minLat as Lang.Float;
    var maxLat as Lang.Float;
    var minLon as Lang.Float;
    var maxLon as Lang.Float;
    var paletteOffset as Lang.Number;
    var tileEntriesOffset as Lang.Number;
    var pixelDataStart as Lang.Number;

    function initialize() {
        version = 0;
        paletteSize = 0;
        tileCount = 0;
        minLat = 0.0f;
        maxLat = 0.0f;
        minLon = 0.0f;
        maxLon = 0.0f;
        paletteOffset = 0;
        tileEntriesOffset = 0;
        pixelDataStart = 0;
    }
}

class TileEntry {
    var zoom as Lang.Number;
    var tileX as Lang.Number;
    var tileY as Lang.Number;
    var width as Lang.Number;
    var height as Lang.Number;
    var pixelOffset as Lang.Number;
    var pixelLength as Lang.Number;

    function initialize() {
        zoom = 0;
        tileX = 0;
        tileY = 0;
        width = 0;
        height = 0;
        pixelOffset = 0;
        pixelLength = 0;
    }
}

class TileDecoder {

    // App.Storage.setValue has a per-value limit (~32 KB in simulator / older devices).
    // We split large bundles into 16 KB chunks stored under numbered keys.
    static const STORAGE_CHUNK = 16 * 1024;

    // LRU manifest: App.Storage key "bm" → Array<String> of 8-char short keys,
    // ordered oldest → newest. On storage full we evict the oldest entry.
    static const MANIFEST_KEY = "bm";
    static const MAX_CACHED_BUNDLES = 32; // safety cap, actual limit is device storage

    static function storageKey(bundleId as Lang.String) as Lang.String {
        return "b_" + bundleId.substring(0, 8);
    }

    // ── Manifest helpers ────────────────────────────────────────────────────

    static function loadManifest() as Lang.Array<Lang.String> {
        try {
            var m = App.Storage.getValue(MANIFEST_KEY);
            if (m instanceof Lang.Array) { return m as Lang.Array<Lang.String>; }
        } catch (e) {}
        return [] as Lang.Array<Lang.String>;
    }

    static function saveManifest(manifest as Lang.Array<Lang.String>) as Void {
        try {
            App.Storage.setValue(MANIFEST_KEY, manifest);
        } catch (e) {
            System.println("[Tiles] saveManifest failed: " + e.getErrorMessage());
        }
    }

    // Remove shortKey from manifest in-place. Returns true if it was present.
    static function removeFromManifest(shortKey as Lang.String, manifest as Lang.Array<Lang.String>) as Lang.Boolean {
        for (var i = 0; i < manifest.size(); i++) {
            if (shortKey.equals(manifest[i])) {
                manifest.remove(manifest[i]);
                return true;
            }
        }
        return false;
    }

    // ── Storage primitives ──────────────────────────────────────────────────

    // Write chunks for shortKey. Returns true on success; cleans up on failure.
    static function writeChunks(shortKey as Lang.String, blob as Lang.ByteArray, numChunks as Lang.Number) as Lang.Boolean {
        var totalSize = blob.size();
        var key = "b_" + shortKey;
        try {
            for (var i = 0; i < numChunks; i++) {
                var start = i * STORAGE_CHUNK;
                var end = start + STORAGE_CHUNK;
                if (end > totalSize) { end = totalSize; }
                App.Storage.setValue(key + "_" + i, blob.slice(start, end));
            }
            App.Storage.setValue(key + "_n", numChunks);
            App.Storage.setValue(key + "_sz", totalSize);
            return true;
        } catch (e) {
            System.println("[Tiles] writeChunks b_" + shortKey + " failed: " + e.getErrorMessage());
            deleteBundleByKey(shortKey);
            return false;
        }
    }

    static function deleteBundleByKey(shortKey as Lang.String) as Void {
        var key = "b_" + shortKey;
        try {
            var numChunks = App.Storage.getValue(key + "_n");
            if (numChunks instanceof Lang.Number) {
                for (var i = 0; i < (numChunks as Lang.Number); i++) {
                    App.Storage.deleteValue(key + "_" + i);
                }
                App.Storage.deleteValue(key + "_n");
                App.Storage.deleteValue(key + "_sz");
            }
        } catch (e) {}
    }

    // ── Public API ──────────────────────────────────────────────────────────

    // Returns true if the bundle is already persisted in Storage (fast check).
    static function exists(bundleId as Lang.String) as Lang.Boolean {
        var nc = App.Storage.getValue(storageKey(bundleId) + "_n");
        return nc instanceof Lang.Number;
    }

    // Persist blob with LRU eviction: if storage is full, evict the oldest
    // cached bundle and retry until either success or nothing left to evict.
    static function persist(bundleId as Lang.String, blob as Lang.ByteArray) as Lang.Boolean {
        var totalSize = blob.size();
        var numChunks = (totalSize + STORAGE_CHUNK - 1) / STORAGE_CHUNK;
        var shortKey = bundleId.substring(0, 8);
        System.println("[Tiles] persist " + totalSize + "B in " + numChunks + " chunks key=b_" + shortKey);

        var manifest = loadManifest();

        // Already cached — promote to MRU and return immediately
        if (removeFromManifest(shortKey, manifest)) {
            manifest.add(shortKey);
            saveManifest(manifest);
            System.println("[Tiles] already cached, promoted to MRU cached=" + manifest.size());
            return true;
        }

        // Try to write; evict oldest on failure and retry
        while (true) {
            if (writeChunks(shortKey, blob, numChunks)) {
                manifest.add(shortKey);
                if (manifest.size() > MAX_CACHED_BUNDLES) {
                    var excess = manifest[0] as Lang.String;
                    manifest.remove(excess);
                    deleteBundleByKey(excess);
                }
                saveManifest(manifest);
                System.println("[Tiles] persist ok cached=" + manifest.size());
                return true;
            }
            if (manifest.size() == 0) {
                System.println("[Tiles] persist failed: storage full, nothing left to evict");
                return false;
            }
            var oldest = manifest[0] as Lang.String;
            manifest.remove(oldest);
            deleteBundleByKey(oldest);
            System.println("[Tiles] evicted b_" + oldest + " to make room, remaining=" + manifest.size());
        }
        return false;
    }

    static function load(bundleId as Lang.String) as Lang.ByteArray? {
        var key = storageKey(bundleId);
        try {
            var numChunks = App.Storage.getValue(key + "_n");
            if (!(numChunks instanceof Lang.Number)) {
                System.println("[Tiles] load: no chunk index for " + key);
                return null;
            }
            var nc = (numChunks as Lang.Number);
            // Guard against OOM: the whole blob is assembled in RAM here, and
            // addAll() growth peaks well above the final size. A bundle over ~12
            // 16 KB chunks (~192 KB) blows the Fenix heap during load and crashes
            // (and would crash-loop on every startup while it sits in Storage).
            // Refuse it — a fresh, smaller bundle from the phone will replace it.
            if (nc > 12) {
                appLog("bundle too big (" + nc + " chunks) — skip load");
                return null;
            }
            // Use addAll() (native C++) instead of a Monkey C byte-copy loop —
            // the loop costs ~4 bytecodes per byte and trips the watchdog on bundles
            // larger than ~20 KB. addAll() is a single native call regardless of size.
            var blob = new [0]b as Lang.ByteArray;
            for (var i = 0; i < nc; i++) {
                var chunk = App.Storage.getValue(key + "_" + i);
                if (!(chunk instanceof Lang.ByteArray)) {
                    System.println("[Tiles] load: missing chunk " + i);
                    return null;
                }
                blob.addAll(chunk as Lang.ByteArray);
            }
            System.println("[Tiles] load: assembled " + blob.size() + "B from " + nc + " chunks");
            return blob;
        } catch (e) {
            System.println("[Tiles] load failed: " + e.getErrorMessage());
        }
        return null;
    }

    static function deleteBundle(bundleId as Lang.String) as Void {
        var shortKey = bundleId.substring(0, 8);
        deleteBundleByKey(shortKey);
        var manifest = loadManifest();
        if (removeFromManifest(shortKey, manifest)) {
            saveManifest(manifest);
        }
    }

    static function readU8(blob as Lang.ByteArray, offset as Lang.Number) as Lang.Number {
        return blob[offset] & 0xFF;
    }

    static function readU16BE(blob as Lang.ByteArray, offset as Lang.Number) as Lang.Number {
        return ((blob[offset] & 0xFF) << 8) | (blob[offset + 1] & 0xFF);
    }

    static function readI32BE(blob as Lang.ByteArray, offset as Lang.Number) as Lang.Number {
        // Returns a signed 32-bit Number. For our use (offsets, sizes < 2^31)
        // this is equivalent to uint32, since payloads never exceed 2 GB.
        var b0 = blob[offset] & 0xFF;
        var b1 = blob[offset + 1] & 0xFF;
        var b2 = blob[offset + 2] & 0xFF;
        var b3 = blob[offset + 3] & 0xFF;
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }

    static function readF32BE(blob as Lang.ByteArray, offset as Lang.Number) as Lang.Float {
        var bits = readI32BE(blob, offset);
        var sign = ((bits >> 31) & 0x1) != 0 ? -1.0f : 1.0f;
        var exponent = ((bits >> 23) & 0xFF);
        var mantissa = bits & 0x7FFFFF;
        if (exponent == 0xFF) {
            return sign * 1e38f;
        }
        if (exponent == 0) {
            return 0.0f;
        }
        var m = 1.0f + (mantissa.toFloat() / 8388608.0f);
        var e = (exponent - 127).toFloat();
        return (sign * m * Math.pow(2.0, e).toFloat()).toFloat();
    }

    static function parseHeader(blob as Lang.ByteArray) as BundleHeader? {
        if (blob == null || blob.size() < HEADER_FIXED_SIZE) {
            return null;
        }
        if (blob[0] != BUNDLE_MAGIC_0 || blob[1] != BUNDLE_MAGIC_1 ||
            blob[2] != BUNDLE_MAGIC_2 || blob[3] != BUNDLE_MAGIC_3) {
            System.println("[Tiles] bad magic");
            return null;
        }
        var h = new BundleHeader();
        h.version = readU8(blob, 4);
        h.paletteSize = readU8(blob, 5);
        h.tileCount = readU16BE(blob, 6);
        h.minLat = readF32BE(blob, 8);
        h.maxLat = readF32BE(blob, 12);
        h.minLon = readF32BE(blob, 16);
        h.maxLon = readF32BE(blob, 20);
        if (h.version != BUNDLE_VERSION) {
            System.println("[Tiles] unsupported version " + h.version);
            return null;
        }
        h.paletteOffset = HEADER_FIXED_SIZE;
        h.tileEntriesOffset = h.paletteOffset + h.paletteSize * 3;
        h.pixelDataStart = h.tileEntriesOffset + h.tileCount * TILE_ENTRY_SIZE;
        if (blob.size() < h.pixelDataStart) {
            System.println("[Tiles] blob truncated, need " + h.pixelDataStart + " have " + blob.size());
            return null;
        }
        System.println("[Tiles] header v=" + h.version + " palette=" + h.paletteSize + " tiles=" + h.tileCount);
        return h;
    }

    static function parsePalette(blob as Lang.ByteArray, header as BundleHeader) as Lang.Array<Lang.Number> {
        var palette = new [header.paletteSize];
        var off = header.paletteOffset;
        for (var i = 0; i < header.paletteSize; i++) {
            var r = blob[off] & 0xFF;
            var g = blob[off + 1] & 0xFF;
            var b = blob[off + 2] & 0xFF;
            palette[i] = (r << 16) | (g << 8) | b;
            off += 3;
        }
        return palette;
    }

    static function parseTileEntry(blob as Lang.ByteArray, header as BundleHeader, index as Lang.Number) as TileEntry {
        var off = header.tileEntriesOffset + index * TILE_ENTRY_SIZE;
        var t = new TileEntry();
        t.zoom = readU8(blob, off);
        t.tileX = readI32BE(blob, off + 1);
        t.tileY = readI32BE(blob, off + 5);
        t.width = readU16BE(blob, off + 9);
        t.height = readU16BE(blob, off + 11);
        t.pixelOffset = readI32BE(blob, off + 13);
        t.pixelLength = readI32BE(blob, off + 17);
        return t;
    }

    // Fill [startCol, startCol+numCols) columns of a tile into an existing Dc.
    // Called incrementally (a few columns per onUpdate frame) to stay within
    // the CIQ watchdog budget.
    static function fillTileColumns(
        blob as Lang.ByteArray,
        entry as TileEntry,
        palette as Lang.Array<Lang.Number>,
        bdc as Graphics.Dc,
        startCol as Lang.Number,
        numCols as Lang.Number
    ) as Void {
        var w = entry.width;
        var h = entry.height;
        var off = entry.pixelOffset;
        var palSize = palette.size();
        var endCol = startCol + numCols;
        if (endCol > w) { endCol = w; }
        for (var x = startCol; x < endCol; x++) {
            var colBase = off + x * h;
            var runStart = 0;
            var runIdx = blob[colBase] & 0xFF;
            if (runIdx >= palSize) { runIdx = 0; }
            for (var y = 1; y <= h; y++) {
                var curIdx = (y < h) ? (blob[colBase + y] & 0xFF) : -1;
                if (curIdx >= palSize) { curIdx = 0; }
                if (curIdx != runIdx) {
                    bdc.setColor(palette[runIdx], Graphics.COLOR_TRANSPARENT);
                    bdc.fillRectangle(x, runStart, 1, y - runStart);
                    runStart = y;
                    runIdx = curIdx;
                }
            }
        }
    }
}
