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

const APP_VERSION = "2026-05-10 dbg15";

class DecodedTile {
    var bmp as Graphics.BufferedBitmap;
    var localX as Lang.Number;
    var localY as Lang.Number;
    var width as Lang.Number;
    var height as Lang.Number;

    function initialize(b as Graphics.BufferedBitmap, x as Lang.Number, y as Lang.Number, w as Lang.Number, h as Lang.Number) {
        bmp = b;
        localX = x;
        localY = y;
        width = w;
        height = h;
    }
}

class NavigationView extends WatchUi.View {
    var _route as RouteData;
    var _mapMode as Lang.Number;
    var _bundleId as Lang.String?;
    var _bundleHeader as BundleHeader?;
    var _palette as Lang.Array<Lang.Number>?;
    var _decodedTiles as Lang.Array<DecodedTile>?;
    var _bundlePixelW as Lang.Number;
    var _bundlePixelH as Lang.Number;

    // Incremental tile decode state. After loadBundle() parses the header,
    // these fields drive column-by-column decoding inside onUpdate().
    // Each onUpdate() call processes COLS_PER_FRAME columns of the current tile.
    var _pendingBlob as Lang.ByteArray?;
    var _pendingEntries as Lang.Array?;
    var _pendingMinX as Lang.Number;
    var _pendingMinY as Lang.Number;
    var _pendingTileIndex as Lang.Number;
    var _pendingColIndex as Lang.Number;
    var _currentTileBmp as Graphics.BufferedBitmap?;
    var _currentTileDc as Graphics.Dc?;

    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
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

    function initialize(route as RouteData) {
        View.initialize();
        _route = route;
        _mapMode = readMapModeProperty();
        _bundleId = readLastBundleIdProperty();
        _bundleHeader = null;
        _palette = null;
        _decodedTiles = null;
        _bundlePixelW = 0;
        _bundlePixelH = 0;
        _currentLat = 0.0f;
        _currentLon = 0.0f;
        _onlineMode = true;
        _bundleLoadAttempted = false;
        _pendingBlob = null;
        _pendingEntries = null;
        _pendingMinX = 0;
        _pendingMinY = 0;
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
        _bundlePixelW = 0;
        _bundlePixelH = 0;
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

    // Phase 1 of tile decode: parse entries and compute layout. Fast (no pixels).
    // Sets up _pendingBlob/_pendingEntries so onUpdate() can decode one tile per frame.
    function prepareDecode(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
        _pendingBlob = null;
        _pendingEntries = null;
        _decodedTiles = [] as Lang.Array<DecodedTile>;
        if (hdr.tileCount == 0 || _palette == null) {
            return;
        }
        var entries = new [hdr.tileCount];
        var minTileX = -1;
        var minTileY = -1;
        var maxTileX = -1;
        var maxTileY = -1;
        var anyW = 0;
        var anyH = 0;
        for (var i = 0; i < hdr.tileCount; i++) {
            var e = TileDecoder.parseTileEntry(blob, hdr, i);
            entries[i] = e;
            anyW = e.width;
            anyH = e.height;
            if (minTileX < 0 || e.tileX < minTileX) { minTileX = e.tileX; }
            if (minTileY < 0 || e.tileY < minTileY) { minTileY = e.tileY; }
            if (e.tileX > maxTileX) { maxTileX = e.tileX; }
            if (e.tileY > maxTileY) { maxTileY = e.tileY; }
        }
        _bundlePixelW = (maxTileX - minTileX + 1) * anyW;
        _bundlePixelH = (maxTileY - minTileY + 1) * anyH;
        _pendingMinX = minTileX;
        _pendingMinY = minTileY;
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
            var localX = (entry.tileX - _pendingMinX) * entry.width;
            var localY = (entry.tileY - _pendingMinY) * entry.height;
            if (_decodedTiles == null) { _decodedTiles = [] as Lang.Array<DecodedTile>; }
            (_decodedTiles as Lang.Array<DecodedTile>).add(
                new DecodedTile(_currentTileBmp as Graphics.BufferedBitmap, localX, localY, entry.width, entry.height)
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
        for (var i = 1; i < _route.lats.size(); i++) {
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
    }

    function updateGpsPosition(lat as Lang.Float, lon as Lang.Float) as Void {
        _currentLat = lat;
        _currentLon = lon;
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
        drawModeBadge(dc);
        drawDebugLine(dc);
        drawOffRouteBannerIfNeeded(dc);
    }

    function drawCustomTiles(dc as Graphics.Dc) as Void {
        if (_bundleHeader == null) {
            drawTopText(dc, _bundleId == null ? "TILES: no bundle" : "TILES: header parse failed", Graphics.COLOR_YELLOW);
            return;
        }
        var tiles = _decodedTiles;
        if (tiles == null || tiles.size() == 0) {
            // Decoder is currently disabled (see loadBundle). Show that we
            // have the bundle and the parsed header so the user can confirm
            // arrival without crashing on synchronous decode.
            var hdr = _bundleHeader as BundleHeader;
            drawTopText(dc, "TILES: have bundle, " + hdr.tileCount + " tiles (decode off)", Graphics.COLOR_LT_GRAY);
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var offsetX = (w - _bundlePixelW) / 2;
        var offsetY = (h - _bundlePixelH) / 2;
        for (var i = 0; i < tiles.size(); i++) {
            var t = tiles[i];
            dc.drawBitmap(offsetX + t.localX, offsetY + t.localY, t.bmp);
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

    function drawModeBadge(dc as Graphics.Dc) as Void {
        var label = "";
        if (_mapMode == BG_MODE_TILES) {
            var bid = _bundleId;
            var snippet = (bid != null && (bid as Lang.String).length() >= 8) ? (bid as Lang.String).substring(0, 8) : "—";
            var have = _decodedTiles != null && (_decodedTiles as Lang.Array).size() > 0;
            label = "[TILES] " + snippet + (have ? " ok" : " ∅");
        } else if (_mapMode == BG_MODE_NONE) {
            label = "[NONE]";
        }
        if (label.equals("")) {
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var th = dc.getFontHeight(Graphics.FONT_XTINY);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h - th - 4, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Yellow band under the title showing the most recent debug message.
    // tickDebug() rotates _debugCurrent at most once per second so each
    // event is readable on screen.
    function drawDebugLine(dc as Graphics.Dc) as Void {
        if (_debugCurrent == null) { return; }
        var w = dc.getWidth();
        var bandH = dc.getFontHeight(Graphics.FONT_TINY) + 8;
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

    // Project a (lat, lon) to screen coords using the tracked viewport.
    // Returns null if the viewport is not yet configured (no route applied).
    function projectPoint(dc as Graphics.Dc, lat as Lang.Float, lon as Lang.Float) as Lang.Array<Lang.Number>? {
        if (!_viewSet) { return null; }
        var lonSpan = _viewLon1 - _viewLon0;
        var latSpan = _viewLat0 - _viewLat1;
        if (lonSpan == 0.0 || latSpan == 0.0) { return null; }
        var fx = (lon - _viewLon0) / lonSpan;
        var fy = (_viewLat0 - lat) / latSpan;
        var x = (fx * dc.getWidth()).toNumber();
        var y = (fy * dc.getHeight()).toNumber();
        return [x, y] as Lang.Array<Lang.Number>;
    }

    function drawPolylineOverlay(dc as Graphics.Dc) as Void {
        var pts = _route.lats.size();
        if (pts < 2) {
            return;
        }
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        var prev = projectPoint(dc, _route.lats[0], _route.lons[0]);
        for (var i = 1; i < pts; i++) {
            var cur = projectPoint(dc, _route.lats[i], _route.lons[i]);
            if (prev != null && cur != null) {
                dc.drawLine(prev[0], prev[1], cur[0], cur[1]);
            }
            prev = cur;
        }
    }

    function drawWaypointOverlay(dc as Graphics.Dc) as Void {
        var cnt = _route.markerLats.size();
        for (var i = 0; i < cnt; i++) {
            var pt = projectPoint(dc, _route.markerLats[i], _route.markerLons[i]);
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
        var pt = projectPoint(dc, _currentLat, _currentLon);
        if (pt == null) { return; }
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(pt[0], pt[1], 6);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(pt[0], pt[1], 6);
    }

    function drawTopBand(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var name = _route.routeName != null ? _route.routeName : "Route";
        var fitted = fitText(dc, name, Graphics.FONT_TINY, w - 50);
        var th = dc.getFontHeight(Graphics.FONT_TINY);
        var topBandH = th + 6;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, 0, w, topBandH);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 3, Graphics.FONT_TINY, fitted, Graphics.TEXT_JUSTIFY_CENTER);
        // BLE indicator: filled green = online, outline gray = offline
        var dotX = w - 10;
        var dotY = topBandH / 2;
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
        if (_currentLat == 0.0f && _currentLon == 0.0f) { return; }
        if (!NavigationCalculator.isOffRoute(_route, _currentLat, _currentLon)) { return; }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var text = "OFF ROUTE";
        var tw = dc.getTextWidthInPixels(text, Graphics.FONT_TINY);
        var th = dc.getFontHeight(Graphics.FONT_TINY);
        var pad = 6;
        var bx = (w - tw) / 2 - pad;
        var by = h - th - 14;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(bx, by, tw + pad * 2, th + 4);
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, by + 2, Graphics.FONT_TINY, text, Graphics.TEXT_JUSTIFY_CENTER);
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

    function cycleMapMode() as Void {
        var next = (_mapMode + 1) % 3;
        setMapModeAndPersist(next);
    }
}
