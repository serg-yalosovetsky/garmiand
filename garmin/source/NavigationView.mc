using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
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

const APP_VERSION = "2026-07-05 dbg39";

class NavigationView extends WatchUi.View {
    var _route as RouteData;
    var _mapMode as Lang.Number;
    var _bundleId as Lang.String?;
    var _bundleHeader as BundleHeader?;
    var _palette as Lang.Array<Lang.Number>?;
    // Tile decode + composited-layer rendering (state + methods live in TileRenderer).
    var _tiles as TileRenderer;

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
    // (driven from onUpdate, no dedicated timer) pops one per second so each is
    // visible at least 1 s.
    var _debugQueue as Lang.Array<Lang.String>;
    var _debugCurrent as Lang.String?;
    var _debugUntilMs as Lang.Number;

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

    // GPS-jump stash/pop state (START double-press toggles between the saved
    // view and the current GPS position).
    var _gpsJumpActive as Lang.Boolean;
    var _savedPanLat as Lang.Float;
    var _savedPanLon as Lang.Float;
    var _savedZoomFactor as Lang.Float;
    var _savedActiveZoom as Lang.Number;

    function initialize(route as RouteData) {
        View.initialize();
        _route = route;
        _mapMode = readMapModeProperty();
        _bundleId = readLastBundleIdProperty();
        _bundleHeader = null;
        _palette = null;
        _tiles = new TileRenderer(self);
        _currentLat = 0.0f;
        _currentLon = 0.0f;
        _isOffRoute = false;
        _onlineMode = true;
        _bundleLoadAttempted = false;
        _activeOsmZoom = 15;
        _pendingZoomSwitch = false;
        _availableZooms = null;
        _debugQueue = [] as Lang.Array<Lang.String>;
        _debugCurrent = null;
        _debugUntilMs = 0;
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
        _gpsJumpActive = false;
        _savedPanLat = 0.0f;
        _savedPanLon = 0.0f;
        _savedZoomFactor = 1.0f;
        _savedActiveZoom = 15;
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
        // No dedicated debug timer: tickDebug() is driven from onUpdate() so we
        // never hold an always-on 250 ms Timer slot (keep active timers minimal).
    }

    function onHide() as Void {
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

    function loadBundle(bundleId as Lang.String) as Void {
        _tiles.clear();
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
                _tiles.prepareDecode(blob, hdr);
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

        // Default to a READABLE window (~2.5 km) centred on the route start, not
        // the whole-route fit — a long route squeezed into the screen makes the
        // map/labels unreadably tiny. The viewport bbox stays the whole route, so
        // zooming out still reveals the full route (coarse z13); zooming in / GPS
        // follow keeps street detail. _zoomFactor scales the bbox down to ~2.5 km.
        var midLat = (_viewLat0 + _viewLat1) * 0.5f;
        var cosLat = Math.cos(midLat.toDouble() * Math.PI / 180.0).toFloat();
        if (cosLat < 0.1f) { cosLat = 0.1f; }
        var spanKmLat = (_viewLat0 - _viewLat1) * 111.0f;
        var spanKmLon = (_viewLon1 - _viewLon0) * 111.0f * cosLat;
        var biggerKm = spanKmLat > spanKmLon ? spanKmLat : spanKmLon;
        var zf = biggerKm / 2.5f;
        if (zf < 1.0f) { zf = 1.0f; }
        if (zf > 16.0f) { zf = 16.0f; }
        _zoomFactor = zf;
        // Centre the initial view on the start marker ("S"), not the bbox centre.
        var ctrLat = (_viewLat0 + _viewLat1) * 0.5f;
        var ctrLon = (_viewLon0 + _viewLon1) * 0.5f;
        _panOffsetLat = (_route.lats[0] - ctrLat).toFloat();
        _panOffsetLon = (_route.lons[0] - ctrLon).toFloat();
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
            _tiles.clear();
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
        tickDebug(); // rotate the on-screen debug band (no dedicated timer)

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
        if (_tiles.isDecoding()) {
            _tiles.decodeNextTile();
            if (_tiles.isDecoding()) {
                WatchUi.requestUpdate(); // more tiles remaining
            }
        }

        // A route is optional: with a viewport from the bundle bbox (map sent
        // without a route) we still render TILES. Waiting screen only when
        // there is neither a route nor a viewable bundle.
        if (!_route.isComplete && !_viewSet) {
            MapOverlays.drawWaitingScreen(dc, self);
            return;
        }

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        if (_mapMode == BG_MODE_TILES) {
            _tiles.drawCustomTiles(dc);
        }
        // BG_MODE_NATIVE is no longer rendered by MapView (sim crashes); we
        // draw a plain black background and the same overlay everywhere.
        MapOverlays.drawPolyline(dc, self);
        MapOverlays.drawWaypoints(dc, self);
        MapOverlays.drawPosition(dc, self);

        MapOverlays.drawTopBand(dc, self);
        MapOverlays.drawDebugLine(dc, self);
        MapOverlays.drawOffRoute(dc, self);
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


    function getMapMode() as Lang.Number {
        return _mapMode;
    }

    function getBundleHeader() as BundleHeader? {
        return _bundleHeader;
    }

    function isDecodePending() as Lang.Boolean {
        return _tiles.isDecoding() || _pendingZoomSwitch;
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

    // START double-press: stash/pop the current view around a GPS jump.
    // 1st double-press: remember the current pan+zoom, then jump to GPS.
    // 2nd double-press: restore the remembered view ("pop").
    function toggleGpsJump() as Void {
        if (!_gpsJumpActive) {
            _savedPanLat = _panOffsetLat;
            _savedPanLon = _panOffsetLon;
            _savedZoomFactor = _zoomFactor;
            _savedActiveZoom = _activeOsmZoom;
            _gpsJumpActive = true;
            centerToGps();
            pushDebug("-> GPS");
        } else {
            _panOffsetLat = _savedPanLat;
            _panOffsetLon = _savedPanLon;
            _zoomFactor = _savedZoomFactor;
            _gpsJumpActive = false;
            checkZoomSwitch(); // restore zoom level if it changed at GPS
            pushDebug("<- back");
            WatchUi.requestUpdate();
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
        _tiles.clear();
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
            _tiles.prepareDecode(blob, _bundleHeader as BundleHeader);
        } catch (e) {
            pushDebug("zswitch EX: " + e.getErrorMessage());
        }
    }
}
