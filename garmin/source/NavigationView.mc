using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.WatchUi;

const BG_MODE_NATIVE = 0;
const BG_MODE_TILES = 1;
const BG_MODE_NONE = 2;

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

    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _onlineMode as Lang.Boolean;
    var _fetchStatus as Lang.String?;
    var _bundleLoadAttempted as Lang.Boolean;

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
        _fetchStatus = null;
        _bundleLoadAttempted = false;
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
    }

    function loadBundle(bundleId as Lang.String) as Void {
        clearDecodedTiles();
        var blob = TileDecoder.load(bundleId);
        if (blob == null) {
            System.println("[Tiles] no blob for " + bundleId);
            _bundleHeader = null;
            _palette = null;
            return;
        }
        var hdr = TileDecoder.parseHeader(blob);
        if (hdr == null) {
            _bundleHeader = null;
            _palette = null;
            return;
        }
        _bundleHeader = hdr;
        _palette = TileDecoder.parsePalette(blob, hdr);
        decodeAllTiles(blob, hdr);
        System.println("[Tiles] loaded bundle " + bundleId + " tiles=" + hdr.tileCount + " bundlePx=" + _bundlePixelW + "x" + _bundlePixelH);
    }

    function decodeAllTiles(blob as Lang.ByteArray, hdr as BundleHeader) as Void {
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
        var tiles = [] as Lang.Array<DecodedTile>;
        for (var j = 0; j < hdr.tileCount; j++) {
            var entry = entries[j] as TileEntry;
            var bmp = TileDecoder.decodeTile(blob, entry, _palette as Lang.Array<Lang.Number>);
            if (bmp != null) {
                var localX = (entry.tileX - minTileX) * entry.width;
                var localY = (entry.tileY - minTileY) * entry.height;
                tiles.add(new DecodedTile(bmp, localX, localY, entry.width, entry.height));
            }
        }
        _decodedTiles = tiles;
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
        _fetchStatus = s;
        WatchUi.requestUpdate();
    }

    function setBundleId(id as Lang.String?) as Void {
        _bundleId = id;
        try {
            App.Properties.setValue("last_bundle_id", id != null ? id : "");
        } catch (e) {
        }
        if (id != null) {
            loadBundle(id as Lang.String);
        } else {
            _bundleHeader = null;
            _palette = null;
            clearDecodedTiles();
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        if (!_route.isComplete) {
            drawWaitingScreen(dc);
            return;
        }

        ensureBundleLoaded();

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
        drawOffRouteBannerIfNeeded(dc);
    }

    function drawCustomTiles(dc as Graphics.Dc) as Void {
        if (_bundleHeader == null) {
            drawTopText(dc, _bundleId == null ? "TILES: no bundle" : "TILES: header parse failed", Graphics.COLOR_YELLOW);
            return;
        }
        var tiles = _decodedTiles;
        if (tiles == null || tiles.size() == 0) {
            drawTopText(dc, "TILES: decode failed", Graphics.COLOR_YELLOW);
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
        if (label.equals("") && _fetchStatus == null) {
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var th = dc.getFontHeight(Graphics.FONT_XTINY);
        if (!label.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h - th - 4, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
        }
        // Fetch status — рисуем сверху (под title band), чтобы не перекрывался
        // OFF ROUTE баннером и режимным лейблом внизу.
        if (_fetchStatus != null) {
            var bandH = dc.getFontHeight(Graphics.FONT_TINY) + 8;
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.fillRectangle(0, bandH, w, th + 4);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, bandH + 2, Graphics.FONT_XTINY, _fetchStatus as Lang.String, Graphics.TEXT_JUSTIFY_CENTER);
        }
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
