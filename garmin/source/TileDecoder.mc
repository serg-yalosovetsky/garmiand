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
const BUNDLE_VERSION = 1;
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

    static function storageKey(bundleId as Lang.String) as Lang.String {
        return "bundle_" + bundleId;
    }

    static function persist(bundleId as Lang.String, blob as Lang.ByteArray) as Lang.Boolean {
        try {
            App.Storage.setValue(storageKey(bundleId), blob);
            return true;
        } catch (e) {
            System.println("[Tiles] persist failed: " + e.getErrorMessage());
            return false;
        }
    }

    static function load(bundleId as Lang.String) as Lang.ByteArray? {
        try {
            var v = App.Storage.getValue(storageKey(bundleId));
            if (v instanceof Lang.ByteArray) {
                return v as Lang.ByteArray;
            }
        } catch (e) {
            System.println("[Tiles] load failed: " + e.getErrorMessage());
        }
        return null;
    }

    static function deleteBundle(bundleId as Lang.String) as Void {
        try {
            App.Storage.deleteValue(storageKey(bundleId));
        } catch (e) {
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

    /**
     * Decode one tile's column-major palette indices into a BufferedBitmap.
     * Pixel layout (must match android/.../TileQuantizer.kt#quantizeBitmap):
     *   pixels[col * height + row] = palette index (0..63).
     */
    static function decodeTile(
        blob as Lang.ByteArray,
        entry as TileEntry,
        palette as Lang.Array<Lang.Number>
    ) as Graphics.BufferedBitmap? {
        var bmp;
        try {
            bmp = Graphics.createBufferedBitmap({
                :width => entry.width,
                :height => entry.height,
                :palette => palette,
            }).get();
        } catch (e) {
            System.println("[Tiles] createBufferedBitmap failed: " + e.getErrorMessage());
            return null;
        }
        if (bmp == null) {
            return null;
        }
        var bdc = bmp.getDc();
        var off = entry.pixelOffset;
        var w = entry.width;
        var h = entry.height;
        for (var x = 0; x < w; x++) {
            var colBase = off + x * h;
            for (var y = 0; y < h; y++) {
                var idx = blob[colBase + y] & 0xFF;
                if (idx >= palette.size()) { idx = 0; }
                bdc.setColor(palette[idx], Graphics.COLOR_TRANSPARENT);
                bdc.drawPoint(x, y);
            }
        }
        return bmp;
    }
}
