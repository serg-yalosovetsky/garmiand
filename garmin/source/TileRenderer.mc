using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;

// One decoded map tile: a BufferedBitmap plus its XYZ coords for Web-Mercator
// placement at render time.
class DecodedTile {
    var bmp as Graphics.BufferedBitmap;
    var zoom as Lang.Number;
    var tileX as Lang.Number;
    var tileY as Lang.Number;

    function initialize(b as Graphics.BufferedBitmap, z as Lang.Number, tx as Lang.Number, ty as Lang.Number) {
        bmp = b;
        zoom = z;
        tileX = tx;
        tileY = ty;
    }
}

// Viewport-driven tile decode. Instead of decoding EVERY tile of the active zoom
// up front (which caps coverage at the graphics-RAM budget), it decodes only the
// MAX_DECODED tiles nearest the screen centre that are currently on screen, and
// evicts the rest. Panning/zooming shifts that target set — new tiles decode,
// far ones drop. This decouples how many tiles a bundle can carry (Storage) from
// how many are decoded at once (RAM), so bundles can cover much larger areas.
class TileRenderer {
    // Max tiles decoded (held as BufferedBitmaps) at once. 8 × 16 KB (z15 128px)
    // = 128 KB, comfortably within the Fenix 7 graphics pool.
    static const MAX_DECODED = 8;

    var _view as NavigationView;
    var _blob as Lang.ByteArray?;
    var _entries as Lang.Array?;              // active-zoom TileEntry list (metadata only)
    var _cache as Lang.Array<DecodedTile>;    // decoded tiles currently held

    // Incremental decode-in-progress (one tile, a few columns per frame).
    var _decEntry as TileEntry?;
    var _decBmp as Graphics.BufferedBitmap?;
    var _decDc as Graphics.Dc?;
    var _decCol as Lang.Number;

    function initialize(view as NavigationView) {
        _view = view;
        _blob = null;
        _entries = null;
        _cache = [] as Lang.Array<DecodedTile>;
        _decEntry = null;
        _decBmp = null;
        _decDc = null;
        _decCol = 0;
    }

    function clear() as Void {
        _blob = null;
        _entries = null;
        _cache = [] as Lang.Array<DecodedTile>;
        _decEntry = null;
        _decBmp = null;
        _decDc = null;
        _decCol = 0;
    }

    function hasTiles() as Lang.Boolean {
        return _cache.size() > 0;
    }

    // Parse the active-zoom entries (metadata only). Decode is deferred to the
    // viewport-driven step in decodeNextTile().
    function prepareDecode(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
        clear();
        if (hdr.tileCount == 0 || _view._palette == null) {
            return;
        }
        var entries = [] as Lang.Array;
        for (var i = 0; i < hdr.tileCount; i++) {
            var e = TileDecoder.parseTileEntry(blob, hdr, i);
            if (e.zoom == _view._activeOsmZoom) {
                entries.add(e);
            }
        }
        if (entries.size() == 0) {
            _view.pushDebug("no z" + _view._activeOsmZoom + " tiles");
            return;
        }
        _entries = entries;
        _blob = blob;
        _view.pushDebug("z" + _view._activeOsmZoom + " " + entries.size() + "t vp");
    }

    // Web Mercator: tile row ty at zoom (n = 2^zoom) → latitude of its north edge.
    function tileYToLat(ty as Lang.Number, n as Lang.Number) as Lang.Float {
        var yFrac = Math.PI * (1.0 - 2.0 * ty.toDouble() / n.toDouble());
        var ex = Math.pow(Math.E, yFrac).toFloat();
        var sinhVal = (ex - 1.0f / ex) * 0.5f;
        return Math.toDegrees(Math.atan(sinhVal.toDouble())).toFloat();
    }

    // Screen rect [x,y,w,h] for a tile, or null if unprojectable/degenerate.
    function rectForTile(zoom as Lang.Number, tx as Lang.Number, ty as Lang.Number) as Lang.Array<Lang.Number>? {
        var n = 1 << zoom;
        var lonNW = tx.toFloat() / n.toFloat() * 360.0f - 180.0f;
        var lonSE = (tx + 1).toFloat() / n.toFloat() * 360.0f - 180.0f;
        var latNW = tileYToLat(ty, n);
        var latSE = tileYToLat(ty + 1, n);
        var nw = _view.projectPoint(latNW, lonNW);
        var se = _view.projectPoint(latSE, lonSE);
        if (nw == null || se == null) { return null; }
        var w = se[0] - nw[0];
        var h = se[1] - nw[1];
        if (w <= 0 || h <= 0) { return null; }
        return [nw[0], nw[1], w, h] as Lang.Array<Lang.Number>;
    }

    function rectVisible(r as Lang.Array<Lang.Number>) as Lang.Boolean {
        return r[0] < _view._screenW && (r[0] + r[2]) > 0 && r[1] < _view._screenH && (r[1] + r[3]) > 0;
    }

    // The ≤MAX_DECODED on-screen entries nearest the screen centre — the tiles we
    // actually decode. Everything else in the bundle stays undecoded metadata.
    function targetEntries() as Lang.Array {
        var out = [] as Lang.Array;
        if (_entries == null) { return out; }
        var cx = _view._screenW / 2;
        var cy = _view._screenH / 2;
        var vis = [] as Lang.Array; // [distSq, entry]
        var entries = _entries as Lang.Array;
        for (var i = 0; i < entries.size(); i++) {
            var e = entries[i] as TileEntry;
            var r = rectForTile(e.zoom, e.tileX, e.tileY);
            if (r == null || !rectVisible(r)) { continue; }
            var dx = r[0] + r[2] / 2 - cx;
            var dy = r[1] + r[3] / 2 - cy;
            vis.add([dx * dx + dy * dy, e]);
        }
        // insertion sort by distance (vis is small, ≤ tile count)
        for (var i = 1; i < vis.size(); i++) {
            var v = vis[i];
            var j = i - 1;
            while (j >= 0 && (vis[j][0] as Lang.Number) > (v[0] as Lang.Number)) {
                vis[j + 1] = vis[j];
                j--;
            }
            vis[j + 1] = v;
        }
        var lim = vis.size() < MAX_DECODED ? vis.size() : MAX_DECODED;
        for (var i = 0; i < lim; i++) {
            out.add(vis[i][1]);
        }
        return out;
    }

    function cacheIndex(tx as Lang.Number, ty as Lang.Number) as Lang.Number {
        for (var i = 0; i < _cache.size(); i++) {
            var t = _cache[i] as DecodedTile;
            if (t.tileX == tx && t.tileY == ty) { return i; }
        }
        return -1;
    }

    function inTargets(targets as Lang.Array, tx as Lang.Number, ty as Lang.Number) as Lang.Boolean {
        for (var i = 0; i < targets.size(); i++) {
            var e = targets[i] as TileEntry;
            if (e.tileX == tx && e.tileY == ty) { return true; }
        }
        return false;
    }

    // True while a target tile still needs decoding — keeps onUpdate stepping.
    function isDecoding() as Lang.Boolean {
        if (_decEntry != null) { return true; }
        var targets = targetEntries();
        for (var i = 0; i < targets.size(); i++) {
            var e = targets[i] as TileEntry;
            if (cacheIndex(e.tileX, e.tileY) < 0) { return true; }
        }
        return false;
    }

    // One decode step: prune the cache to the current target set, then continue or
    // start decoding a target tile (a few columns per frame for the watchdog).
    function decodeNextTile() as Void {
        if (_blob == null || _entries == null || _view._palette == null) { return; }
        var targets = targetEntries();

        // Evict cached tiles no longer in the target set (off-screen / too far).
        var i = 0;
        while (i < _cache.size()) {
            var t = _cache[i] as DecodedTile;
            if (!inTargets(targets, t.tileX, t.tileY)) {
                _cache.remove(_cache[i]);
            } else {
                i++;
            }
        }

        if (_decEntry != null) { stepDecode(); return; }

        for (var k = 0; k < targets.size(); k++) {
            var e = targets[k] as TileEntry;
            if (cacheIndex(e.tileX, e.tileY) < 0) {
                _decEntry = e;
                _decBmp = null;
                _decDc = null;
                _decCol = 0;
                stepDecode();
                return;
            }
        }
    }

    function stepDecode() as Void {
        var e = _decEntry as TileEntry;
        if (_decBmp == null) {
            try {
                _decBmp = Graphics.createBufferedBitmap({
                    :width => e.width,
                    :height => e.height,
                    :palette => _view._palette,
                }).get() as Graphics.BufferedBitmap;
                _decDc = (_decBmp as Graphics.BufferedBitmap).getDc();
            } catch (ex) {
                _view.pushDebug("bmp fail: " + ex.getErrorMessage());
                _decEntry = null; // skip this tile
                return;
            }
            _decCol = 0;
        }
        var cpf = 1024 / e.height;
        if (cpf < 1) { cpf = 1; }
        if (cpf > 8) { cpf = 8; }
        TileDecoder.fillTileColumns(
            _blob as Lang.ByteArray, e, _view._palette as Lang.Array<Lang.Number>,
            _decDc as Graphics.Dc, _decCol, cpf
        );
        _decCol += cpf;
        if (_decCol >= e.width) {
            _cache.add(new DecodedTile(_decBmp as Graphics.BufferedBitmap, e.zoom, e.tileX, e.tileY));
            if (_cache.size() > MAX_DECODED) { _cache.remove(_cache[0]); } // safety cap
            _decEntry = null;
            _decBmp = null;
            _decDc = null;
            _decCol = 0;
        }
    }

    // Draw the decoded (visible) tiles, each scaled to its geographic screen rect.
    function drawCustomTiles(dc as Graphics.Dc) as Void {
        if (_cache.size() == 0 || !_view._viewSet) { return; }
        for (var i = 0; i < _cache.size(); i++) {
            var t = _cache[i] as DecodedTile;
            var r = rectForTile(t.zoom, t.tileX, t.tileY);
            if (r == null) { continue; }
            dc.drawScaledBitmap(r[0], r[1], r[2], r[3], t.bmp);
        }
    }
}
