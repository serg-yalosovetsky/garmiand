using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

const BG_MODE_NATIVE = 0;
const BG_MODE_TILES = 1;
const BG_MODE_NONE = 2;

// Interact sub-modes within BG_MODE_TILES (cycled by SELECT).
// SELECT cycle: ZOOM → PAN_NS → PAN_WE → JUMP → exits TILES mode.
// In JUMP mode: UP = center on GPS position, DOWN = center on route.
const INTERACT_ZOOM   = 0;   // UP = zoom in,   DOWN = zoom out
const INTERACT_PAN_NS = 1;   // UP = pan north,  DOWN = pan south
const INTERACT_PAN_WE = 2;   // UP = pan west,   DOWN = pan east
const INTERACT_JUMP   = 3;   // UP = go to GPS,  DOWN = go to route

const APP_VERSION = "2026-05-11 03:54 dbg29";

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

class NavigationView extends WatchUi.View {
    var _route as RouteData;
    var _mapMode as Lang.Number;
    var _bundleId as Lang.String?;
    var _bundleHeader as BundleHeader?;
    var _palette as Lang.Array<Lang.Number>?;
    var _decodedTiles as Lang.Array<DecodedTile>?;

    // Incremental tile decode state. After loadBundle() parses the header,
    // these fields drive column-by-column decoding inside onUpdate().
    // Each onUpdate() call processes COLS_PER_FRAME columns of the current tile.
    var _pendingBlob as Lang.ByteArray?;
    var _pendingEntries as Lang.Array?;
    var _pendingTileIndex as Lang.Number;
    var _pendingColIndex as Lang.Number;
    var _currentTileBmp as Graphics.BufferedBitmap?;
    var _currentTileDc as Graphics.Dc?;

    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _isOffRoute as Lang.Boolean;
    var _onlineMode as Lang.Boolean;
    var _bundleLoadAttempted as Lang.Boolean;

    // On-screen debug log. pushDebug() enqueues a message; tickDebug()
    // (timer-driven) pops one per second so each is visible at least 1 s.
    var _debugQueue as Lang.Array<Lang.String>;
    var _debugCurrent as Lang.String?;
    var _debugUntilMs as Lang.Number;
    var _debugTimer as Timer.Timer?;

    // Viewport we asked MapView to render. We track it manually because
    // there is no latLonToScreenPoint() in the MapView API — overlay
    // drawing in TILES/NONE modes uses these to project route points.
    var _viewLat0 as Lang.Float;  // north (max lat)
    var _viewLat1 as Lang.Float;  // south (min lat)
    var _viewLon0 as Lang.Float;  // west  (min lon)
    var _viewLon1 as Lang.Float;  // east  (max lon)
    var _viewSet as Lang.Boolean;
    var _screenW as Lang.Number;
    var _screenH as Lang.Number;

    // Pan state — degrees added to the viewport center.
    // Reset to 0 by centerToGps(). Applied in projectPoint().
    var _panOffsetLat as Lang.Float;
    var _panOffsetLon as Lang.Float;
    var _interactMode as Lang.Number; // INTERACT_ZOOM / PAN_NS / PAN_WE / JUMP
    // Zoom: >1 = zoomed in (viewport shrunk), <1 = zoomed out. Reset with pan.
    var _zoomFactor as Lang.Float;

    function initialize(route as RouteData) {
        View.initialize();
        _route = route;
        _mapMode = readMapModeProperty();
        _bundleId = readLastBundleIdProperty();
        _bundleHeader = null;
        _palette = null;
        _decodedTiles = null;
        _currentLat = 0.0f;
        _currentLon = 0.0f;
        _isOffRoute = false;
        _onlineMode = true;
        _bundleLoadAttempted = false;
        _pendingBlob = null;
        _pendingEntries = null;
        _pendingTileIndex = 0;
        _pendingColIndex = 0;
        _currentTileBmp = null;
        _currentTileDc = null;
        _debugQueue = [] as Lang.Array<Lang.String>;
        _debugCurrent = null;
        _debugUntilMs = 0;
        _debugTimer = null;
        _viewLat0 = 0.0f;
        _viewLat1 = 0.0f;
        _viewLon0 = 0.0f;
        _viewLon1 = 0.0f;
        _viewSet = false;
        _screenW = 0;
        _screenH = 0;
        _panOffsetLat = 0.0f;
        _panOffsetLon = 0.0f;
        _interactMode = INTERACT_ZOOM;
        _zoomFactor = 1.0f;
        // NB: don't call loadBundle here — decodeAllTiles allocates BufferedBitmaps
        // via Graphics.createBufferedBitmap, which requires the view's graphics
        // context. That context isn't ready until onShow(). Calling it from
        // initialize() crashes the app on startup if last_bundle_id points to
        // a real bundle in Storage.
    }

    function onShow() as Void {
        if (_debugTimer == null) {
            var t = new Timer.Timer();
            t.start(method(:tickDebug), 250, true);
            _debugTimer = t;
        }
    }

    function onHide() as Void {
        if (_debugTimer != null) {
            (_debugTimer as Timer.Timer).stop();
            _debugTimer = null;
        }
    }

    function pushDebug(msg as Lang.String) as Void {
        _debugQueue.add(msg);
        System.println("[DBG] " + msg);
        WatchUi.requestUpdate();
    }

    function tickDebug() as Void {
        var now = System.getTimer();
        if (_debugCurrent != null && now < _debugUntilMs) {
            return;
        }
        if (_debugQueue.size() > 0) {
            _debugCurrent = _debugQueue[0];
            _debugQueue.remove(_debugQueue[0]);
            _debugUntilMs = now + 1000;
            WatchUi.requestUpdate();
        } else if (_debugCurrent != null) {
            // queue drained — let the last message linger another second,
            // then clear so the screen isn't permanently occupied.
            if (now >= _debugUntilMs + 2000) {
                _debugCurrent = null;
                WatchUi.requestUpdate();
            }
        }
    }

    function ensureBundleLoaded() as Void {
        if (_bundleLoadAttempted) { return; }
        _bundleLoadAttempted = true;
        if (_bundleId == null) { return; }
        try {
            loadBundle(_bundleId as Lang.String);
        } catch (e) {
            System.println("[Tiles] loadBundle failed: " + e.getErrorMessage());
        }
    }

    function clearDecodedTiles() as Void {
        _decodedTiles = null;
        _pendingBlob = null;
        _pendingEntries = null;
        _pendingTileIndex = 0;
        _pendingColIndex = 0;
        _currentTileBmp = null;
        _currentTileDc = null;
    }

    function loadBundle(bundleId as Lang.String) as Void {
        clearDecodedTiles();
        pushDebug("load: " + bundleId.substring(0, 8));
        var blob = TileDecoder.load(bundleId);
        if (blob == null) {
            System.println("[Tiles] no blob for " + bundleId);
            pushDebug("load: no blob");
            _bundleHeader = null;
            _palette = null;
            return;
        }
        pushDebug("load: blob " + blob.size() + "B");
        var hdr = TileDecoder.parseHeader(blob);
        if (hdr == null) {
            pushDebug("load: bad header");
            _bundleHeader = null;
            _palette = null;
            return;
        }
        _bundleHeader = hdr;
        pushDebug("hdr: tiles=" + hdr.tileCount);
        try {
            _palette = TileDecoder.parsePalette(blob, hdr);
            pushDebug("palette ok (" + (_palette as Lang.Array).size() + ")");
        } catch (e) {
            System.println("[Tiles] palette parse failed: " + e.getErrorMessage());
            pushDebug("palette FAIL");
            _palette = null;
        }
        if (_palette != null) {
            try {
                prepareDecode(blob, hdr);
            } catch (e) {
                pushDebug("prepareDecode EX: " + e.getErrorMessage());
            }
        }
        System.println("[Tiles] loaded bundle " + bundleId + " tiles=" + hdr.tileCount);
    }

    // Phase 1 of tile decode: parse entries. Fast (no pixels).
    // Sets up _pendingBlob/_pendingEntries so onUpdate() can decode one tile per frame.
    function prepareDecode(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
        _pendingBlob = null;
        _pendingEntries = null;
        _decodedTiles = [] as Lang.Array<DecodedTile>;
        if (hdr.tileCount == 0 || _palette == null) {
            return;
        }
        var entries = new [hdr.tileCount];
        for (var i = 0; i < hdr.tileCount; i++) {
            entries[i] = TileDecoder.parseTileEntry(blob, hdr, i);
        }
        _pendingEntries = entries;
        _pendingBlob = blob;
        _pendingTileIndex = 0;
        pushDebug("decode: 0/" + hdr.tileCount + " tiles");
    }

    // Phase 2: column-by-column tile decode. Called from onUpdate() until done.
    // Processes COLS_PER_FRAME columns per call to stay under the watchdog budget.
    function decodeNextTile() as Void {
        if (_pendingBlob == null || _pendingEntries == null || _bundleHeader == null || _palette == null) {
            return;
        }
        var hdr = _bundleHeader as BundleHeader;
        if (_pendingTileIndex >= hdr.tileCount) {
            _pendingBlob = null;
            return;
        }
        var entry = (_pendingEntries as Lang.Array)[_pendingTileIndex] as TileEntry;

        // Allocate BufferedBitmap for the current tile if not yet done.
        if (_currentTileBmp == null) {
            try {
                _currentTileBmp = Graphics.createBufferedBitmap({
                    :width => entry.width,
                    :height => entry.height,
                    :palette => _palette,
                }).get() as Graphics.BufferedBitmap;
                _currentTileDc = (_currentTileBmp as Graphics.BufferedBitmap).getDc();
            } catch (e) {
                pushDebug("bmp fail: " + e.getErrorMessage());
                _pendingTileIndex++;
                _pendingColIndex = 0;
                return;
            }
            _pendingColIndex = 0;
        }

        // Fill COLS_PER_FRAME columns into the current bitmap's DC.
        TileDecoder.fillTileColumns(
            _pendingBlob as Lang.ByteArray,
            entry,
            _palette as Lang.Array<Lang.Number>,
            _currentTileDc as Graphics.Dc,
            _pendingColIndex,
            8 // columns per frame — keep iterations ≤ 8*h ≈ 1024
        );
        _pendingColIndex += 8;

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
            if (_pendingTileIndex >= hdr.tileCount) {
                _pendingBlob = null;
                _pendingEntries = null;
                pushDebug("decoded " + hdr.tileCount + " tiles");
            }
        }
    }

    function readMapModeProperty() as Lang.Number {
        try {
            var v = App.Properties.getValue("map_mode");
            if (v instanceof Lang.Number) { return v as Lang.Number; }
        } catch (e) {
        }
        return BG_MODE_NATIVE;
    }

    function readLastBundleIdProperty() as Lang.String? {
        try {
            var v = App.Properties.getValue("last_bundle_id");
            if (v instanceof Lang.String && (v as Lang.String).length() > 0) {
                return v as Lang.String;
            }
        } catch (e) {
        }
        return null;
    }

    function setMapModeAndPersist(mode as Lang.Number) as Void {
        _mapMode = mode;
        try {
            App.Properties.setValue("map_mode", mode);
        } catch (e) {
            System.println("[Map] persist map_mode failed: " + e.getErrorMessage());
        }
        WatchUi.requestUpdate();
    }

    function setOnlineMode(enabled as Lang.Boolean) as Void {
        _onlineMode = enabled;
        WatchUi.requestUpdate();
    }

    function applyRoute(route as RouteData) as Void {
        _route = route;
        if (_route.lats.size() == 0) {
            return;
        }
        var minLat = _route.lats[0];
        var maxLat = _route.lats[0];
        var minLon = _route.lons[0];
        var maxLon = _route.lons[0];
        var routeSize = _route.lats.size();
        for (var i = 1; i < routeSize; i++) {
            if (_route.lats[i] < minLat) { minLat = _route.lats[i]; }
            if (_route.lats[i] > maxLat) { maxLat = _route.lats[i]; }
            if (_route.lons[i] < minLon) { minLon = _route.lons[i]; }
            if (_route.lons[i] > maxLon) { maxLon = _route.lons[i]; }
        }
        var spanLat = (maxLat - minLat).toFloat();
        var spanLon = (maxLon - minLon).toFloat();
        if (spanLat < 0.0005) { spanLat = 0.0005f; }
        if (spanLon < 0.0005) { spanLon = 0.0005f; }
        var pad = 0.15f;
        var padLat = spanLat * pad;
        var padLon = spanLon * pad;
        _viewLat0 = (maxLat + padLat).toFloat();
        _viewLat1 = (minLat - padLat).toFloat();
        _viewLon0 = (minLon - padLon).toFloat();
        _viewLon1 = (maxLon + padLon).toFloat();
        _viewSet = true;
        _panOffsetLat = 0.0f;
        _panOffsetLon = 0.0f;
        _zoomFactor = 1.0f;
    }

    function updateGpsPosition(lat as Lang.Float, lon as Lang.Float) as Void {
        _currentLat = lat;
        _currentLon = lon;
        _isOffRoute = _route.isComplete && NavigationCalculator.isOffRoute(_route, lat, lon);
        WatchUi.requestUpdate();
    }

    function setFetchStatus(s as Lang.String?) as Void {
        // Backwards-compatible shim — funnels callers into the debug queue.
        if (s != null) {
            pushDebug(s as Lang.String);
        }
    }

    function setBundleId(id as Lang.String?) as Void {
        _bundleId = id;
        _bundleLoadAttempted = false;
        try {
            App.Properties.setValue("last_bundle_id", id != null ? id : "");
        } catch (e) {
        }
        if (id != null) {
            pushDebug("setBundleId " + (id as Lang.String).substring(0, 8));
            // Don't call loadBundle() here — HTTP/BLE callback watchdog budget is too short.
            // ensureBundleLoaded() in onUpdate() handles the actual load.
        } else {
            _bundleHeader = null;
            _palette = null;
            clearDecodedTiles();
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();

        var app = App.getApp();
        if (app instanceof GarmiandApp) {
            (app as GarmiandApp).processPendingPersist();
            (app as GarmiandApp).processPendingTileChunk();
        }
        ensureBundleLoaded();

        // Incremental decode: one tile per frame to stay within watchdog budget.
        if (_pendingBlob != null) {
            decodeNextTile();
            if (_pendingBlob != null) {
                WatchUi.requestUpdate(); // more tiles remaining
            }
        }

        if (!_route.isComplete) {
            drawWaitingScreen(dc);
            return;
        }

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        if (_mapMode == BG_MODE_TILES) {
            drawCustomTiles(dc);
        }
        // BG_MODE_NATIVE is no longer rendered by MapView (sim crashes); we
        // draw a plain black background and the same overlay everywhere.
        drawPolylineOverlay(dc);
        drawWaypointOverlay(dc);
        drawPositionOverlay(dc);

        drawTopBand(dc);
        drawDebugLine(dc);
        drawOffRouteBannerIfNeeded(dc);
    }

    // Web Mercator: tile row ty at zoom (n = 2^zoom) → latitude of the tile's north edge.
    function tileYToLat(ty as Lang.Number, n as Lang.Number) as Lang.Float {
        var yFrac = Math.PI * (1.0 - 2.0 * ty.toDouble() / n.toDouble());
        var ex = Math.pow(Math.E, yFrac).toFloat();
        var sinhVal = (ex - 1.0f / ex) * 0.5f;
        return Math.toDegrees(Math.atan(sinhVal.toDouble())).toFloat();
    }

    // Returns [screenX, screenY, screenW, screenH] for a decoded tile, or null.
    // Tiles are positioned via geographic projection, not pixel offsets, so they
    // render at the correct scale regardless of zoom level or viewport size.
    function tileScreenRect(t as DecodedTile) as Lang.Array<Lang.Number>? {
        var n = 1 << t.zoom;
        var lonNW = t.tileX.toFloat() / n.toFloat() * 360.0f - 180.0f;
        var lonSE = (t.tileX + 1).toFloat() / n.toFloat() * 360.0f - 180.0f;
        var latNW = tileYToLat(t.tileY, n);
        var latSE = tileYToLat(t.tileY + 1, n);
        var nw = projectPoint(latNW, lonNW);
        var se = projectPoint(latSE, lonSE);
        if (nw == null || se == null) { return null; }
        var sw = se[0] - nw[0];
        var sh = se[1] - nw[1];
        if (sw <= 0 || sh <= 0) { return null; }
        return [nw[0], nw[1], sw, sh] as Lang.Array<Lang.Number>;
    }

    function drawCustomTiles(dc as Graphics.Dc) as Void {
        var tiles = _decodedTiles;
        if (tiles == null || tiles.size() == 0 || !_viewSet) { return; }
        for (var i = 0; i < tiles.size(); i++) {
            var t = tiles[i] as DecodedTile;
            var r = tileScreenRect(t);
            if (r == null) { continue; }
            dc.drawScaledBitmap(r[0], r[1], r[2], r[3], t.bmp);
        }
    }

    function drawCenterText(dc as Graphics.Dc, text as Lang.String, color as Lang.Number) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Place diagnostic text above center so the GPS dot doesn't sit on top of it.
    function drawTopText(dc as Graphics.Dc, text as Lang.String, color as Lang.Number) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 4, Graphics.FONT_TINY, text, Graphics.TEXT_JUSTIFY_CENTER);
    }


    // Yellow band under the title showing the most recent debug message.
    // tickDebug() rotates _debugCurrent at most once per second so each
    // event is readable on screen.
    function drawDebugLine(dc as Graphics.Dc) as Void {
        if (_debugCurrent == null) { return; }
        var w = dc.getWidth();
        var bandH = dc.getFontHeight(Graphics.FONT_TINY) + 26;
        var th = dc.getFontHeight(Graphics.FONT_XTINY);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, bandH, w, th + 4);
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        var queued = _debugQueue.size();
        var suffix = queued > 0 ? "  +" + queued : "";
        dc.drawText(w / 2, bandH + 2, Graphics.FONT_XTINY, (_debugCurrent as Lang.String) + suffix, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawWaitingScreen(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h / 2 - 25, Graphics.FONT_MEDIUM, "Garmiand", Graphics.TEXT_JUSTIFY_CENTER);
        var statusText;
        if (_route.expectedChunkCount > 0) {
            var pct = (_route.receivedChunkCount * 100 / _route.expectedChunkCount).toString() + "%";
            statusText = "Syncing " + pct;
        } else {
            statusText = "Waiting...";
        }
        dc.drawText(cx, h / 2 + 10, Graphics.FONT_SMALL, statusText, Graphics.TEXT_JUSTIFY_CENTER);
        var vth = dc.getFontHeight(Graphics.FONT_XTINY);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 4) / 5 - vth / 2, Graphics.FONT_XTINY, "v " + APP_VERSION, Graphics.TEXT_JUSTIFY_CENTER);
        drawDebugLine(dc);
    }

    // Project a (lat, lon) to screen coords using the tracked viewport + pan offset + zoom.
    // Returns null if the viewport is not yet configured (no route applied).
    function projectPoint(lat as Lang.Float, lon as Lang.Float) as Lang.Array<Lang.Number>? {
        if (!_viewSet) { return null; }
        var halfLat = (_viewLat0 - _viewLat1) * 0.5f / _zoomFactor;
        var halfLon = (_viewLon1 - _viewLon0) * 0.5f / _zoomFactor;
        if (halfLat == 0.0f || halfLon == 0.0f) { return null; }
        var cLat = (_viewLat0 + _viewLat1) * 0.5f + _panOffsetLat;
        var cLon = (_viewLon0 + _viewLon1) * 0.5f + _panOffsetLon;
        var fx = (lon - (cLon - halfLon)) / (halfLon * 2.0f);
        var fy = ((cLat + halfLat) - lat) / (halfLat * 2.0f);
        var x = (fx * _screenW).toNumber();
        var y = (fy * _screenH).toNumber();
        return [x, y] as Lang.Array<Lang.Number>;
    }

    function drawPolylineOverlay(dc as Graphics.Dc) as Void {
        var pts = _route.lats.size();
        if (pts < 2) {
            return;
        }
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        var prev = projectPoint(_route.lats[0], _route.lons[0]);
        for (var i = 1; i < pts; i++) {
            var cur = projectPoint(_route.lats[i], _route.lons[i]);
            if (prev != null && cur != null) {
                dc.drawLine(prev[0], prev[1], cur[0], cur[1]);
            }
            prev = cur;
        }
    }

    function drawWaypointOverlay(dc as Graphics.Dc) as Void {
        var cnt = _route.markerLats.size();
        for (var i = 0; i < cnt; i++) {
            var pt = projectPoint(_route.markerLats[i], _route.markerLons[i]);
            if (pt == null) { continue; }
            var x = pt[0];
            var y = pt[1];
            var title = _route.markerTitles[i];
            if ("Start".equals(title)) {
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, y, 6);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawCircle(x, y, 6);
                dc.drawText(x + 8, y - 8, Graphics.FONT_TINY, "S", Graphics.TEXT_JUSTIFY_LEFT);
            } else if ("Finish".equals(title)) {
                dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(x - 6, y - 6, 12, 12);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawRectangle(x - 6, y - 6, 12, 12);
                dc.drawText(x + 8, y - 8, Graphics.FONT_TINY, "F", Graphics.TEXT_JUSTIFY_LEFT);
            } else {
                dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, y, 4);
            }
        }
    }

    function drawPositionOverlay(dc as Graphics.Dc) as Void {
        if (_currentLat == 0.0f && _currentLon == 0.0f) {
            return;
        }
        var pt = projectPoint(_currentLat, _currentLon);
        if (pt == null) { return; }
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(pt[0], pt[1], 6);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(pt[0], pt[1], 6);
    }

    function drawTopBand(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var font = Graphics.FONT_TINY;
        var th = dc.getFontHeight(font);
        var topBandH = th + 26;  // route name at y=20 sits in the wider part of the round screen
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, 0, w, topBandH);

        // Mode line at very top (y=4) — only in TILES mode, where circle is narrow
        // but short labels ("ZOOM", "NS ok", etc.) fit in ~110px visible width there
        if (_mapMode == BG_MODE_TILES) {
            var im = (_interactMode == INTERACT_PAN_NS) ? "NS"
                   : (_interactMode == INTERACT_PAN_WE) ? "WE"
                   : (_interactMode == INTERACT_JUMP)   ? "JMP" : "ZOOM";
            var have = _decodedTiles != null && (_decodedTiles as Lang.Array).size() > 0;
            var modeLabel = im + (have ? " ok" : " -");
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, 4, Graphics.FONT_XTINY, modeLabel, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Route name
        var name = _route.routeName != null ? _route.routeName : "Route";
        var fitted = fitText(dc, name, font, w - 80);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 20, font, fitted, Graphics.TEXT_JUSTIFY_CENTER);

        // BLE indicator near bottom of band where circle is wide enough (w-38≈222 < 229)
        var dotX = w - 38;
        var dotY = topBandH - 4;
        if (_onlineMode) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(dotX, dotY, 5);
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(dotX, dotY, 5);
            dc.drawLine(dotX - 4, dotY - 4, dotX + 4, dotY + 4);
        }
    }

    function drawOffRouteBannerIfNeeded(dc as Graphics.Dc) as Void {
        if (!_isOffRoute) { return; }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var text = "OFF ROUTE";
        var font = Graphics.FONT_XTINY;
        var tw = dc.getTextWidthInPixels(text, font);
        var th = dc.getFontHeight(font);
        var pad = 4;
        var modeBadgeH = th + 10;
        var by = h - th - modeBadgeH - 4;
        var bx = (w - tw) / 2 - pad;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(bx, by, tw + pad * 2, th + 4);
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, by + 2, font, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function fitText(dc as Graphics.Dc, text as Lang.String, font as Graphics.FontType, maxW as Lang.Number) as Lang.String {
        if (dc.getTextWidthInPixels(text, font) <= maxW) {
            return text;
        }
        var ellipsis = "...";
        var n = text.length();
        while (n > 1) {
            n = n - 1;
            var candidate = text.substring(0, n) + ellipsis;
            if (dc.getTextWidthInPixels(candidate, font) <= maxW) {
                return candidate;
            }
        }
        return ellipsis;
    }

    function getMapMode() as Lang.Number {
        return _mapMode;
    }

    // SELECT handler. In TILES mode cycles through interact sub-modes;
    // 4th press (from JUMP) exits TILES. Outside TILES cycles bg mode.
    // Cycle: ZOOM → NS → WE → JUMP → exit TILES
    function cycleMapMode() as Void {
        if (_mapMode == BG_MODE_TILES) {
            if (_interactMode == INTERACT_ZOOM) {
                _interactMode = INTERACT_PAN_NS;
            } else if (_interactMode == INTERACT_PAN_NS) {
                _interactMode = INTERACT_PAN_WE;
            } else if (_interactMode == INTERACT_PAN_WE) {
                _interactMode = INTERACT_JUMP;
            } else {
                // INTERACT_JUMP — exit TILES mode back to plain black
                _interactMode = INTERACT_ZOOM;
                setMapModeAndPersist(BG_MODE_NATIVE);
            }
            System.println("[Map] interact=" + _interactMode + " zoom=" + _zoomFactor);
            WatchUi.requestUpdate();
        } else {
            // Not in TILES — toggle into TILES
            _interactMode = INTERACT_ZOOM;
            setMapModeAndPersist(BG_MODE_TILES);
            System.println("[Map] mapMode=" + _mapMode);
        }
    }

    // Center viewport on current GPS position (JUMP UP / BACK).
    // If no GPS fix yet, falls back to route center.
    function centerToGps() as Void {
        if (_viewSet && (_currentLat != 0.0f || _currentLon != 0.0f)) {
            var routeCtrLat = (_viewLat0 + _viewLat1) * 0.5f;
            var routeCtrLon = (_viewLon0 + _viewLon1) * 0.5f;
            _panOffsetLat = _currentLat - routeCtrLat;
            _panOffsetLon = _currentLon - routeCtrLon;
        } else {
            _panOffsetLat = 0.0f;
            _panOffsetLon = 0.0f;
        }
        _zoomFactor = 1.0f;
        pushDebug("GPS ctr");
        WatchUi.requestUpdate();
    }

    // Center viewport on route bounding box (JUMP DOWN).
    function centerToRoute() as Void {
        _panOffsetLat = 0.0f;
        _panOffsetLon = 0.0f;
        _zoomFactor = 1.0f;
        pushDebug("route ctr");
        WatchUi.requestUpdate();
    }

    // UP button: zoom in (ZOOM), pan north (NS), pan west (WE), or go to GPS (JUMP).
    function interactUp() as Void {
        if (!_viewSet) { return; }
        if (_interactMode == INTERACT_JUMP) {
            centerToGps();
            return;
        }
        if (_interactMode == INTERACT_ZOOM) {
            _zoomFactor = (_zoomFactor * 1.5f).toFloat();
            if (_zoomFactor > 16.0f) { _zoomFactor = 16.0f; }
        } else {
            var stepLat = (_viewLat0 - _viewLat1) * 0.2f / _zoomFactor;
            var stepLon = (_viewLon1 - _viewLon0) * 0.2f / _zoomFactor;
            if (_interactMode == INTERACT_PAN_NS) {
                _panOffsetLat += stepLat;
            } else {
                _panOffsetLon -= stepLon;
            }
        }
        WatchUi.requestUpdate();
    }

    // DOWN button: zoom out (ZOOM), pan south (NS), pan east (WE), or go to route (JUMP).
    function interactDown() as Void {
        if (!_viewSet) { return; }
        if (_interactMode == INTERACT_JUMP) {
            centerToRoute();
            return;
        }
        if (_interactMode == INTERACT_ZOOM) {
            _zoomFactor = (_zoomFactor / 1.5f).toFloat();
            if (_zoomFactor < 0.25f) { _zoomFactor = 0.25f; }
        } else {
            var stepLat = (_viewLat0 - _viewLat1) * 0.2f / _zoomFactor;
            var stepLon = (_viewLon1 - _viewLon0) * 0.2f / _zoomFactor;
            if (_interactMode == INTERACT_PAN_NS) {
                _panOffsetLat -= stepLat;
            } else {
                _panOffsetLon += stepLon;
            }
        }
        WatchUi.requestUpdate();
    }
}
