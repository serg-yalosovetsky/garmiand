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

// Interact sub-modes within BG_MODE_TILES, cycled by a single press of the
// START (mode) button. Three modes only: ZOOM → PAN_NS → PAN_WE → (ZOOM).
// UP/DOWN act per the active mode. Jump-to-GPS moved to a START double-press;
// INTERACT_JUMP is kept only so the legacy handlers still compile.
const INTERACT_ZOOM   = 0;   // UP = zoom in,   DOWN = zoom out
const INTERACT_PAN_NS = 1;   // UP = pan north,  DOWN = pan south
const INTERACT_PAN_WE = 2;   // UP = pan west,   DOWN = pan east
const INTERACT_JUMP   = 3;   // (legacy) not part of the cycle anymore

const APP_VERSION = "2026-07-05 dbg37";

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
    // _pendingEntries holds only the tiles for _activeOsmZoom (filtered in prepareDecode).
    var _pendingBlob as Lang.ByteArray?;
    var _pendingEntries as Lang.Array?;
    var _pendingTileIndex as Lang.Number;
    var _pendingColIndex as Lang.Number;
    var _currentTileBmp as Graphics.BufferedBitmap?;
    var _currentTileDc as Graphics.Dc?;

    // Active OSM zoom level. checkZoomSwitch() maps _zoomFactor → OSM zoom and
    // triggers switchToActiveZoom(). Levels come from the bundle itself
    // (_availableZooms) — historically z12/z13/z15, but any set works.
    var _activeOsmZoom as Lang.Number;
    var _pendingZoomSwitch as Lang.Boolean;
    // Sorted (asc) distinct zoom levels present in the loaded bundle, or null.
    var _availableZooms as Lang.Array<Lang.Number>?;

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

    // Route name is shown for 5 s after applyRoute(), then hidden.
    // 0 = hidden; >0 = System.getTimer() deadline.
    var _routeNameUntilMs as Lang.Number;

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

    // Composited tile layer cache. The decoded tiles are drawn (scaled) ONCE into
    // a single screen-sized BufferedBitmap; subsequent frames blit that buffer with
    // a pixel offset so panning shifts the map "in one piece" instead of re-scaling
    // every tile each frame. Recomposited only when zoom/zoomFactor/viewport change
    // or the pan drifts past half a screen. Falls back to direct per-tile scaling if
    // the buffer can't be allocated — so it can never make things worse than before.
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
        _activeOsmZoom = 15;
        _pendingZoomSwitch = false;
        _availableZooms = null;
        _debugQueue = [] as Lang.Array<Lang.String>;
        _debugCurrent = null;
        _debugUntilMs = 0;
        _debugTimer = null;
        _routeNameUntilMs = 0;
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
        // NB: don't call loadBundle here — decodeAllTiles allocates BufferedBitmaps
        // via Graphics.createBufferedBitmap, which requires the view's graphics
        // context. That context isn't ready until onShow(). Calling it from
        // initialize() crashes the app on startup if last_bundle_id points to
        // a real bundle in Storage.
    }

    function onShow() as Void {
        // Enable touch events now that we are in the foreground. This API is
        // rejected when called before the app is shown (e.g. in App.onStart).
        try {
            WatchUi.configureTouchEvents({:enabled => true});
        } catch (e) {
        }
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
        // Forward to the phone (→ Loki) for off-device debugging.
        var app = App.getApp();
        if (app instanceof GarmiandApp) {
            (app as GarmiandApp).enqueueWatchLog(msg);
        }
        WatchUi.requestUpdate();
    }

    function tickDebug() as Void {
        var now = System.getTimer();
        if (_routeNameUntilMs > 0 && now >= _routeNameUntilMs) {
            _routeNameUntilMs = 0;
            WatchUi.requestUpdate();
        }
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
        // Invalidate the composited layer; keep the buffer allocated for reuse.
        _layerValid = false;
        _layerTileCount = -1;
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
            scanAvailableZooms(blob, hdr);
            applyBundleViewportIfNeeded(hdr);
            try {
                prepareDecode(blob, hdr);
            } catch (e) {
                pushDebug("prepareDecode EX: " + e.getErrorMessage());
            }
        }
        System.println("[Tiles] loaded bundle " + bundleId + " tiles=" + hdr.tileCount);
    }

    // Collect the sorted distinct zoom levels actually present in the bundle and
    // pick the active zoom = nearest to 15 ("normal"/street level). Bundles from
    // MapsCreator may carry any zoom set — never assume a fixed trio.
    function scanAvailableZooms(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
        var zooms = [] as Lang.Array<Lang.Number>;
        for (var i = 0; i < hdr.tileCount; i++) {
            var z = TileDecoder.readU8(blob, hdr.tileEntriesOffset + i * TILE_ENTRY_SIZE);
            var known = false;
            for (var j = 0; j < zooms.size(); j++) {
                if ((zooms[j] as Lang.Number) == z) { known = true; break; }
            }
            if (!known) { zooms.add(z); }
        }
        // insertion sort — the list holds 1-3 elements
        for (var i = 1; i < zooms.size(); i++) {
            var v = zooms[i] as Lang.Number;
            var j = i - 1;
            while (j >= 0 && (zooms[j] as Lang.Number) > v) {
                zooms[j + 1] = zooms[j];
                j--;
            }
            zooms[j + 1] = v;
        }
        _availableZooms = zooms;
        _activeOsmZoom = nearestAvailableZoom(15);
        var zs = "";
        for (var i = 0; i < zooms.size(); i++) {
            zs = zs + (i > 0 ? "," : "") + (zooms[i] as Lang.Number).toString();
        }
        pushDebug("zooms " + zs + " act z" + _activeOsmZoom);
    }

    function nearestAvailableZoom(target as Lang.Number) as Lang.Number {
        var az = _availableZooms;
        if (az == null || (az as Lang.Array).size() == 0) { return target; }
        var zooms = az as Lang.Array<Lang.Number>;
        var best = zooms[0] as Lang.Number;
        var bestDiff = best - target;
        if (bestDiff < 0) { bestDiff = -bestDiff; }
        for (var i = 1; i < zooms.size(); i++) {
            var z = zooms[i] as Lang.Number;
            var d = z - target;
            if (d < 0) { d = -d; }
            if (d < bestDiff) { best = z; bestDiff = d; }
        }
        return best;
    }

    // A map bundle can arrive without a route (sent from MapsCreator). If the
    // route hasn't configured the viewport yet, use the bundle bbox so TILES
    // mode is viewable immediately; applyRoute() will override it later.
    function applyBundleViewportIfNeeded(hdr as BundleHeader) as Void {
        if (_viewSet) { return; }
        if (hdr.maxLat <= hdr.minLat || hdr.maxLon <= hdr.minLon) { return; }
        _viewLat0 = hdr.maxLat;
        _viewLat1 = hdr.minLat;
        _viewLon0 = hdr.minLon;
        _viewLon1 = hdr.maxLon;
        _viewSet = true;
        _panOffsetLat = 0.0f;
        _panOffsetLon = 0.0f;
        _zoomFactor = 1.0f;
        pushDebug("view from bundle bbox");
    }

    // Phase 1 of tile decode: parse entries filtered to _activeOsmZoom.
    // Sets up _pendingBlob/_pendingEntries so onUpdate() can decode one tile per frame.
    function prepareDecode(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
        _pendingBlob = null;
        _pendingEntries = null;
        _decodedTiles = [] as Lang.Array<DecodedTile>;
        if (hdr.tileCount == 0 || _palette == null) {
            return;
        }
        var entries = [] as Lang.Array;
        for (var i = 0; i < hdr.tileCount; i++) {
            var entry = TileDecoder.parseTileEntry(blob, hdr, i);
            if (entry.zoom == _activeOsmZoom) {
                entries.add(entry);
            }
        }
        if (entries.size() == 0) {
            pushDebug("no z" + _activeOsmZoom + " tiles");
            return;
        }
        _pendingEntries = entries;
        _pendingBlob = blob;
        _pendingTileIndex = 0;
        pushDebug("z" + _activeOsmZoom + " " + entries.size() + "/" + hdr.tileCount + "t");
    }

    // Phase 2: column-by-column tile decode. Called from onUpdate() until done.
    // Processes COLS_PER_FRAME columns per call to stay under the watchdog budget.
    // Operates on _pendingEntries which contains only the _activeOsmZoom tiles.
    function decodeNextTile() as Void {
        if (_pendingBlob == null || _pendingEntries == null || _palette == null) {
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
            if (_pendingTileIndex >= tileCount) {
                _pendingBlob = null;
                _pendingEntries = null;
                pushDebug("z" + _activeOsmZoom + " " + tileCount + "t ok");
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
        _routeNameUntilMs = System.getTimer() + 5000;
        checkZoomSwitch();
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
            // A fresh bundle means the user wants to see the map — enter TILES.
            if (_mapMode != BG_MODE_TILES) {
                setMapModeAndPersist(BG_MODE_TILES);
            }
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

        // Zoom switch requested by checkZoomSwitch (called from interactUp/Down/applyRoute).
        // Heavy blob load deferred to onUpdate so it runs under the larger watchdog budget.
        if (_pendingZoomSwitch) {
            _pendingZoomSwitch = false;
            switchToActiveZoom();
        }

        // Incremental decode: one tile per frame to stay within watchdog budget.
        if (_pendingBlob != null) {
            decodeNextTile();
            if (_pendingBlob != null) {
                WatchUi.requestUpdate(); // more tiles remaining
            }
        }

        // A route is optional: with a viewport from the bundle bbox (map sent
        // without a route) we still render TILES. Waiting screen only when
        // there is neither a route nor a viewable bundle.
        if (!_route.isComplete && !_viewSet) {
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
    // drifted from the pan the layer was composited at. Derived from projectPoint:
    // +panLon shifts content left, +panLat shifts content down.
    function layerBlitOffset() as Lang.Array<Lang.Number> {
        var halfLat = (_viewLat0 - _viewLat1) * 0.5f / _zoomFactor;
        var halfLon = (_viewLon1 - _viewLon0) * 0.5f / _zoomFactor;
        var dx = 0;
        var dy = 0;
        if (halfLon != 0.0f) {
            dx = (-(_panOffsetLon - _layerPanLon) / (halfLon * 2.0f) * _screenW).toNumber();
        }
        if (halfLat != 0.0f) {
            dy = ((_panOffsetLat - _layerPanLat) / (halfLat * 2.0f) * _screenH).toNumber();
        }
        return [dx, dy] as Lang.Array<Lang.Number>;
    }

    // Ensure a valid composited layer exists for the current view. Returns true if
    // _layerBmp can be blitted (possibly with a pan offset), false to fall back.
    function ensureLayer(tiles as Lang.Array<DecodedTile>) as Lang.Boolean {
        var stale = !_layerValid
            || _layerBmp == null
            || _layerZoom != _activeOsmZoom
            || _layerZoomFactor != _zoomFactor
            || _layerViewLat0 != _viewLat0
            || _layerViewLon0 != _viewLon0
            || _layerTileCount != tiles.size();
        if (!stale) {
            // Reuse as long as the pan drift stays within half a screen; beyond
            // that the exposed black margin gets too big, so recomposite instead.
            var off = layerBlitOffset();
            var adx = off[0] < 0 ? -off[0] : off[0];
            var ady = off[1] < 0 ? -off[1] : off[1];
            if (adx <= _screenW / 2 && ady <= _screenH / 2) {
                return true;
            }
        }
        return compositeLayer(tiles);
    }

    // (Re)draw all decoded tiles into the screen-sized layer buffer once, recording
    // the pan/zoom/view state it represents. Allocates the buffer lazily; on any
    // allocation failure it disables the cache for the session and returns false so
    // the caller degrades to direct drawing (never worse than the pre-cache path).
    function compositeLayer(tiles as Lang.Array<DecodedTile>) as Lang.Boolean {
        if (_screenW <= 0 || _screenH <= 0 || _palette == null) { return false; }
        try {
            if (_layerBmp == null) {
                _layerBmp = Graphics.createBufferedBitmap({
                    :width => _screenW,
                    :height => _screenH,
                    :palette => _palette,
                }).get() as Graphics.BufferedBitmap;
            }
        } catch (e) {
            _layerBmp = null;
            _layerDisabled = true;
            pushDebug("layer off: " + e.getErrorMessage());
            return false;
        }
        if (_layerBmp == null) { _layerDisabled = true; return false; }
        var ldc = (_layerBmp as Graphics.BufferedBitmap).getDc();
        ldc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        ldc.clear();
        drawTilesDirect(ldc, tiles);
        _layerPanLat = _panOffsetLat;
        _layerPanLon = _panOffsetLon;
        _layerZoom = _activeOsmZoom;
        _layerZoomFactor = _zoomFactor;
        _layerViewLat0 = _viewLat0;
        _layerViewLon0 = _viewLon0;
        _layerTileCount = tiles.size();
        _layerValid = true;
        return true;
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
        var bandH = topBandH(dc);
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

    // Height of the top band. Full (~50px) only while route name is on screen
    // (5s after applyRoute); compact (~26px) otherwise so the map shows through.
    function topBandH(dc as Graphics.Dc) as Lang.Number {
        if (_routeNameUntilMs > 0) {
            return dc.getFontHeight(Graphics.FONT_TINY) + 26;
        }
        return dc.getFontHeight(Graphics.FONT_XTINY) + 10;
    }

    function drawTopBand(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var bh = topBandH(dc);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, 0, w, bh);

        // Mode line at y=4 — only in TILES mode
        if (_mapMode == BG_MODE_TILES) {
            var im = (_interactMode == INTERACT_PAN_NS) ? "NS"
                   : (_interactMode == INTERACT_PAN_WE) ? "WE"
                   : (_interactMode == INTERACT_JUMP)   ? "JMP" : "ZOOM";
            var have = _decodedTiles != null && (_decodedTiles as Lang.Array).size() > 0;
            var dec = _pendingBlob != null;
            var zStatus = dec ? "dec" : (have ? "ok" : "-");
            var modeLabel = im + " z" + _activeOsmZoom.toString() + " " + zStatus;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, 4, Graphics.FONT_XTINY, modeLabel, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Route name — visible for 5 s after applyRoute()
        if (_routeNameUntilMs > 0) {
            var name = _route.routeName != null ? _route.routeName : "Route";
            var fitted = fitText(dc, name, Graphics.FONT_TINY, w - 80);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, 20, Graphics.FONT_TINY, fitted, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // BLE indicator. When band is compact (no route name), y=20 keeps us inside the
        // circle (boundary at y=20 is x≈199; dot centre at w-70=190 + r5 = 195 < 199).
        // When full band, original w-38 at y≈46 is safe (boundary ≈229 there).
        var showName = _routeNameUntilMs > 0;
        var dotX = showName ? (w - 38) : (w - 70);
        var dotY = showName ? (bh - 4) : 20;
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

    function getBundleHeader() as BundleHeader? {
        return _bundleHeader;
    }

    function isDecodePending() as Lang.Boolean {
        return _pendingBlob != null || _pendingZoomSwitch;
    }

    // START single-press handler. Keeps the tile map on screen and cycles the
    // three interaction modes only: ZOOM → PAN_NS → PAN_WE → (ZOOM).
    // If the map is not in TILES mode yet, the first press just enters it.
    function cycleMapMode() as Void {
        if (_mapMode != BG_MODE_TILES) {
            _interactMode = INTERACT_ZOOM;
            setMapModeAndPersist(BG_MODE_TILES);
        } else if (_interactMode == INTERACT_ZOOM) {
            _interactMode = INTERACT_PAN_NS;
        } else if (_interactMode == INTERACT_PAN_NS) {
            _interactMode = INTERACT_PAN_WE;
        } else {
            _interactMode = INTERACT_ZOOM;
        }
        System.println("[Map] interact=" + _interactMode + " zoom=" + _zoomFactor);
        WatchUi.requestUpdate();
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
        checkZoomSwitch();
        pushDebug("GPS ctr");
        WatchUi.requestUpdate();
    }

    // Exit TILES mode back to NATIVE (called on BACK press).
    function exitTilesMode() as Void {
        _interactMode = INTERACT_ZOOM;
        setMapModeAndPersist(BG_MODE_NATIVE);
    }

    // Center viewport on route bounding box (JUMP DOWN).
    function centerToRoute() as Void {
        _panOffsetLat = 0.0f;
        _panOffsetLon = 0.0f;
        _zoomFactor = 1.0f;
        checkZoomSwitch();
        pushDebug("route ctr");
        WatchUi.requestUpdate();
    }

    // Pan viewport by a screen-pixel delta (from touch drag).
    // dx>0 = finger right → reveals west; dy>0 = finger down → reveals north.
    function panByPixels(dx as Lang.Number, dy as Lang.Number) as Void {
        if (!_viewSet || _screenW <= 0 || _screenH <= 0) { return; }
        var halfLat = (_viewLat0 - _viewLat1) * 0.5f / _zoomFactor;
        var halfLon = (_viewLon1 - _viewLon0) * 0.5f / _zoomFactor;
        if (halfLat == 0.0f || halfLon == 0.0f) { return; }
        _panOffsetLat = (_panOffsetLat + dy.toFloat() * halfLat * 2.0f / _screenH.toFloat()).toFloat();
        _panOffsetLon = (_panOffsetLon - dx.toFloat() * halfLon * 2.0f / _screenW.toFloat()).toFloat();
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
            checkZoomSwitch();
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
            checkZoomSwitch();
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

    // Map current _zoomFactor to an OSM zoom level and trigger a tile reload if changed.
    // Thresholds: <0.5 → overview (lowest available), 0.5–3.0 → normal (nearest to 15),
    // ≥3.0 → detail (highest available). Falls back to the fixed z13/z15/z17 trio when
    // no bundle is loaded yet. Sets _pendingZoomSwitch so the actual blob load happens
    // in onUpdate (larger watchdog budget).
    function checkZoomSwitch() as Void {
        var newZoom;
        var az = _availableZooms;
        if (az != null && (az as Lang.Array).size() > 0) {
            var zooms = az as Lang.Array<Lang.Number>;
            if (_zoomFactor >= 3.0f) {
                newZoom = zooms[zooms.size() - 1] as Lang.Number;
            } else if (_zoomFactor <= 0.5f) {
                newZoom = zooms[0] as Lang.Number;
            } else {
                newZoom = nearestAvailableZoom(15);
            }
        } else if (_zoomFactor >= 3.0f) {
            newZoom = 17;
        } else if (_zoomFactor <= 0.5f) {
            newZoom = 13;
        } else {
            newZoom = 15;
        }
        if (newZoom == _activeOsmZoom) { return; }
        _activeOsmZoom = newZoom;
        _pendingZoomSwitch = true;
        WatchUi.requestUpdate();
    }

    // Reload the stored bundle blob and re-run prepareDecode filtered to _activeOsmZoom.
    // Called from onUpdate() to avoid watchdog issues in event-handler callbacks.
    function switchToActiveZoom() as Void {
        clearDecodedTiles();
        if (_bundleId == null || _bundleHeader == null || _palette == null) {
            pushDebug("z" + _activeOsmZoom + " not ready");
            return;
        }
        var blob = TileDecoder.load(_bundleId as Lang.String);
        if (blob == null) {
            pushDebug("z" + _activeOsmZoom + " no blob");
            return;
        }
        try {
            prepareDecode(blob, _bundleHeader as BundleHeader);
        } catch (e) {
            pushDebug("zswitch EX: " + e.getErrorMessage());
        }
    }
}
