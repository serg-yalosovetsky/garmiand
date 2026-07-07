using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;

// One decoded map tile: a BufferedBitmap plus its XYZ coordinates so it can be
// positioned by Web-Mercator projection at render time.
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

// Owns everything about turning a GMND blob into pixels on screen: incremental
// column-by-column tile decode (watchdog-safe), the composited screen-sized
// layer cache, and Web-Mercator tile placement. Split out of NavigationView so
// that file stays an orchestrator. Reads the viewport/palette/screen state from
// the owning NavigationView (`_view`); all decode/layer state lives here.
class TileRenderer {
    var _view as NavigationView;

    // Decoded tiles for the active zoom, ready to blit.
    var _decodedTiles as Lang.Array<DecodedTile>?;

    // Incremental decode cursor (one tile, a few columns per onUpdate frame).
    var _pendingBlob as Lang.ByteArray?;
    var _pendingEntries as Lang.Array?;
    var _pendingTileIndex as Lang.Number;
    var _pendingColIndex as Lang.Number;
    var _currentTileBmp as Graphics.BufferedBitmap?;
    var _currentTileDc as Graphics.Dc?;

    // Composited screen-sized layer cache (blit-with-offset panning).
    var _layerBmp as Graphics.BufferedBitmap?;
    var _layerValid as Lang.Boolean;
    var _layerDisabled as Lang.Boolean; // set once if buffer alloc ever fails
    var _layerZoom as Lang.Number;
    var _layerZoomFactor as Lang.Float;
    var _layerPanLat as Lang.Float;
    var _layerPanLon as Lang.Float;
    var _layerViewLat0 as Lang.Float;
    var _layerViewLon0 as Lang.Float;
    var _layerTileCount as Lang.Number;

    function initialize(view as NavigationView) {
        _view = view;
        _decodedTiles = null;
        _pendingBlob = null;
        _pendingEntries = null;
        _pendingTileIndex = 0;
        _pendingColIndex = 0;
        _currentTileBmp = null;
        _currentTileDc = null;
        _layerBmp = null;
        _layerValid = false;
        _layerDisabled = false;
        _layerZoom = -1;
        _layerZoomFactor = 0.0f;
        _layerPanLat = 0.0f;
        _layerPanLon = 0.0f;
        _layerViewLat0 = 0.0f;
        _layerViewLon0 = 0.0f;
        _layerTileCount = -1;
    }

    // True while tiles are still decoding (drives extra requestUpdate frames).
    function isDecoding() as Lang.Boolean {
        return _pendingBlob != null;
    }

    // True once at least one tile is decoded and ready to draw.
    function hasTiles() as Lang.Boolean {
        return _decodedTiles != null && (_decodedTiles as Lang.Array).size() > 0;
    }

    function clear() as Void {
        _decodedTiles = null;
        _pendingBlob = null;
        _pendingEntries = null;
        _pendingTileIndex = 0;
        _pendingColIndex = 0;
        _currentTileBmp = null;
        _currentTileDc = null;
        // Invalidate the composited layer; keep the buffer allocated for reuse.
        _layerValid = false;
        _layerTileCount = -1;
    }

    // Phase 1 of tile decode: parse entries filtered to the active OSM zoom.
    // Sets up _pendingBlob/_pendingEntries so decodeNextTile() can run per frame.
    function prepareDecode(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
        _pendingBlob = null;
        _pendingEntries = null;
        _decodedTiles = [] as Lang.Array<DecodedTile>;
        if (hdr.tileCount == 0 || _view._palette == null) {
            return;
        }
        var entries = [] as Lang.Array;
        for (var i = 0; i < hdr.tileCount; i++) {
            var entry = TileDecoder.parseTileEntry(blob, hdr, i);
            if (entry.zoom == _view._activeOsmZoom) {
                entries.add(entry);
            }
        }
        if (entries.size() == 0) {
            _view.pushDebug("no z" + _view._activeOsmZoom + " tiles");
            return;
        }
        _pendingEntries = entries;
        _pendingBlob = blob;
        _pendingTileIndex = 0;
        _view.pushDebug("z" + _view._activeOsmZoom + " " + entries.size() + "/" + hdr.tileCount + "t");
    }

    // Phase 2: column-by-column tile decode. Called from onUpdate() until done.
    // Operates on _pendingEntries which contains only the active-zoom tiles.
    function decodeNextTile() as Void {
        if (_pendingBlob == null || _pendingEntries == null || _view._palette == null) {
            return;
        }
        var entries = _pendingEntries as Lang.Array;
        var tileCount = entries.size();
        if (_pendingTileIndex >= tileCount) {
            _pendingBlob = null;
            return;
        }
        var entry = entries[_pendingTileIndex] as TileEntry;

        // Allocate BufferedBitmap for the current tile if not yet done.
        if (_currentTileBmp == null) {
            try {
                _currentTileBmp = Graphics.createBufferedBitmap({
                    :width => entry.width,
                    :height => entry.height,
                    :palette => _view._palette,
                }).get() as Graphics.BufferedBitmap;
                _currentTileDc = (_currentTileBmp as Graphics.BufferedBitmap).getDc();
            } catch (e) {
                _view.pushDebug("bmp fail: " + e.getErrorMessage());
                _pendingTileIndex++;
                _pendingColIndex = 0;
                return;
            }
            _pendingColIndex = 0;
        }

        // Fill colsPerFrame columns into the current bitmap's DC. Keep the
        // per-frame inner-loop iterations (cols × tileHeight) near ≤1024 so the
        // watchdog is safe regardless of tile size: 128px→8 cols, 256px→4 cols.
        var colsPerFrame = 1024 / entry.height;
        if (colsPerFrame < 1) { colsPerFrame = 1; }
        if (colsPerFrame > 8) { colsPerFrame = 8; }
        TileDecoder.fillTileColumns(
            _pendingBlob as Lang.ByteArray,
            entry,
            _view._palette as Lang.Array<Lang.Number>,
            _currentTileDc as Graphics.Dc,
            _pendingColIndex,
            colsPerFrame
        );
        _pendingColIndex += colsPerFrame;

        if (_pendingColIndex >= entry.width) {
            // Tile complete — add to decoded list.
            if (_decodedTiles == null) { _decodedTiles = [] as Lang.Array<DecodedTile>; }
            (_decodedTiles as Lang.Array<DecodedTile>).add(
                new DecodedTile(_currentTileBmp as Graphics.BufferedBitmap, entry.zoom, entry.tileX, entry.tileY)
            );
            _currentTileBmp = null;
            _currentTileDc = null;
            _pendingColIndex = 0;
            _pendingTileIndex++;
            if (_pendingTileIndex >= tileCount) {
                _pendingBlob = null;
                _pendingEntries = null;
                _view.pushDebug("z" + _view._activeOsmZoom + " " + tileCount + "t ok");
            }
        }
    }

    // Web Mercator: tile row ty at zoom (n = 2^zoom) → latitude of the tile's north edge.
    function tileYToLat(ty as Lang.Number, n as Lang.Number) as Lang.Float {
        var yFrac = Math.PI * (1.0 - 2.0 * ty.toDouble() / n.toDouble());
        var ex = Math.pow(Math.E, yFrac).toFloat();
        var sinhVal = (ex - 1.0f / ex) * 0.5f;
        return Math.toDegrees(Math.atan(sinhVal.toDouble())).toFloat();
    }

    // Returns [screenX, screenY, screenW, screenH] for a decoded tile, or null.
    function tileScreenRect(t as DecodedTile) as Lang.Array<Lang.Number>? {
        var n = 1 << t.zoom;
        var lonNW = t.tileX.toFloat() / n.toFloat() * 360.0f - 180.0f;
        var lonSE = (t.tileX + 1).toFloat() / n.toFloat() * 360.0f - 180.0f;
        var latNW = tileYToLat(t.tileY, n);
        var latSE = tileYToLat(t.tileY + 1, n);
        var nw = _view.projectPoint(latNW, lonNW);
        var se = _view.projectPoint(latSE, lonSE);
        if (nw == null || se == null) { return null; }
        var sw = se[0] - nw[0];
        var sh = se[1] - nw[1];
        if (sw <= 0 || sh <= 0) { return null; }
        return [nw[0], nw[1], sw, sh] as Lang.Array<Lang.Number>;
    }

    function drawCustomTiles(dc as Graphics.Dc) as Void {
        var tiles = _decodedTiles;
        if (tiles == null || tiles.size() == 0 || !_view._viewSet) { return; }

        // Fast path: reuse the composited layer and just shift it by the pan delta
        // (move the map "in one piece"). ensureLayer() returns false when the
        // buffer is unavailable/disabled, in which case we fall back to direct draw.
        if (!_layerDisabled && ensureLayer(tiles)) {
            var off = layerBlitOffset();
            dc.drawBitmap(off[0], off[1], _layerBmp as Graphics.BufferedBitmap);
            return;
        }
        drawTilesDirect(dc, tiles);
    }

    // Direct per-tile scaled draw into an arbitrary Dc (screen or the layer buffer).
    function drawTilesDirect(dc as Graphics.Dc, tiles as Lang.Array<DecodedTile>) as Void {
        for (var i = 0; i < tiles.size(); i++) {
            var t = tiles[i] as DecodedTile;
            var r = tileScreenRect(t);
            if (r == null) { continue; }
            dc.drawScaledBitmap(r[0], r[1], r[2], r[3], t.bmp);
        }
    }

    // Pixel offset to blit the composited layer at, given how far the pan has
    // drifted from the pan the layer was composited at.
    function layerBlitOffset() as Lang.Array<Lang.Number> {
        var halfLat = (_view._viewLat0 - _view._viewLat1) * 0.5f / _view._zoomFactor;
        var halfLon = (_view._viewLon1 - _view._viewLon0) * 0.5f / _view._zoomFactor;
        var dx = 0;
        var dy = 0;
        if (halfLon != 0.0f) {
            dx = (-(_view._panOffsetLon - _layerPanLon) / (halfLon * 2.0f) * _view._screenW).toNumber();
        }
        if (halfLat != 0.0f) {
            dy = ((_view._panOffsetLat - _layerPanLat) / (halfLat * 2.0f) * _view._screenH).toNumber();
        }
        return [dx, dy] as Lang.Array<Lang.Number>;
    }

    // Ensure a valid composited layer exists for the current view. Returns true if
    // _layerBmp can be blitted (possibly with a pan offset), false to fall back.
    function ensureLayer(tiles as Lang.Array<DecodedTile>) as Lang.Boolean {
        var stale = !_layerValid
            || _layerBmp == null
            || _layerZoom != _view._activeOsmZoom
            || _layerZoomFactor != _view._zoomFactor
            || _layerViewLat0 != _view._viewLat0
            || _layerViewLon0 != _view._viewLon0
            || _layerTileCount != tiles.size();
        if (!stale) {
            // Reuse as long as the pan drift stays within half a screen; beyond
            // that the exposed black margin gets too big, so recomposite instead.
            var off = layerBlitOffset();
            var adx = off[0] < 0 ? -off[0] : off[0];
            var ady = off[1] < 0 ? -off[1] : off[1];
            if (adx <= _view._screenW / 2 && ady <= _view._screenH / 2) {
                return true;
            }
        }
        return compositeLayer(tiles);
    }

    // (Re)draw all decoded tiles into the screen-sized layer buffer once, recording
    // the pan/zoom/view state it represents. On any allocation failure it disables
    // the cache for the session and returns false so the caller degrades to direct
    // drawing (never worse than the pre-cache path).
    function compositeLayer(tiles as Lang.Array<DecodedTile>) as Lang.Boolean {
        if (_view._screenW <= 0 || _view._screenH <= 0 || _view._palette == null) { return false; }
        try {
            if (_layerBmp == null) {
                // No :palette here: a paletted render target does not reliably
                // accept drawScaledBitmap of the tiles (blank result). The device
                // native depth is already low-color, so memory stays modest.
                _layerBmp = Graphics.createBufferedBitmap({
                    :width => _view._screenW,
                    :height => _view._screenH,
                }).get() as Graphics.BufferedBitmap;
            }
        } catch (e) {
            _layerBmp = null;
            _layerDisabled = true;
            _view.pushDebug("layer off: " + e.getErrorMessage());
            return false;
        }
        if (_layerBmp == null) { _layerDisabled = true; return false; }
        var ldc = (_layerBmp as Graphics.BufferedBitmap).getDc();
        ldc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        ldc.clear();
        drawTilesDirect(ldc, tiles);
        _layerPanLat = _view._panOffsetLat;
        _layerPanLon = _view._panOffsetLon;
        _layerZoom = _view._activeOsmZoom;
        _layerZoomFactor = _view._zoomFactor;
        _layerViewLat0 = _view._viewLat0;
        _layerViewLon0 = _view._viewLon0;
        _layerTileCount = tiles.size();
        _layerValid = true;
        return true;
    }
}
