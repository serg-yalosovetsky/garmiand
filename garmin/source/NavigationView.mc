using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.WatchUi;

class NavigationView extends WatchUi.View {
    var _route as RouteData;

    var _scale as Lang.Float;
    var _centerLat as Lang.Float;
    var _centerLon as Lang.Float;
    var _autoCenter as Lang.Boolean;
    var _lastFittedSize as Lang.Number;

    function initialize(route as RouteData) {
        View.initialize();
        _route = route;
        _scale = 0.0001f;
        _centerLat = 0.0f;
        _centerLon = 0.0f;
        _autoCenter = false;
        _lastFittedSize = -1;
    }

    function fitRoute() as Void {
        var n = _route.lats.size();
        if (n == 0) {
            return;
        }
        var minLat = _route.lats[0];
        var maxLat = _route.lats[0];
        var minLon = _route.lons[0];
        var maxLon = _route.lons[0];
        for (var i = 1; i < n; i++) {
            if (_route.lats[i] < minLat) { minLat = _route.lats[i]; }
            if (_route.lats[i] > maxLat) { maxLat = _route.lats[i]; }
            if (_route.lons[i] < minLon) { minLon = _route.lons[i]; }
            if (_route.lons[i] > maxLon) { maxLon = _route.lons[i]; }
        }
        _centerLat = ((minLat + maxLat) / 2.0).toFloat();
        _centerLon = ((minLon + maxLon) / 2.0).toFloat();
        var spanLat = maxLat - minLat;
        var spanLon = maxLon - minLon;
        var span = (spanLat > spanLon) ? spanLat : spanLon;
        if (span < 0.0001) { span = 0.0001; }
        _scale = (span * 1.3 / 200.0).toFloat();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        if (!_route.isComplete) {
            drawWaitingScreen(dc, w, h);
            return;
        }

        var app = App.getApp() as GarmiandApp;
        var mapBitmap = app._mapBitmap;
        var hasMap = mapBitmap != null
            && app._mapMaxLat > app._mapMinLat
            && app._mapMaxLon > app._mapMinLon;

        if (hasMap) {
            var mx = (w - app._mapWidth) / 2;
            var my = (h - app._mapHeight) / 2;
            dc.drawBitmap(mx, my, mapBitmap);
            drawPolylineMap(dc, app, mx, my);
            drawMarkersMap(dc, app, mx, my);
            drawPositionMap(dc, app, mx, my, w, h);
        } else {
            if (_lastFittedSize != _route.lats.size()) {
                fitRoute();
                _lastFittedSize = _route.lats.size();
            }
            var posLat = app._currentLat;
            var posLon = app._currentLon;
            if (_autoCenter && posLat != 0.0f) {
                _centerLat = posLat;
                _centerLon = posLon;
            }
            drawPolyline(dc, cx, cy);
            drawMarkers(dc, cx, cy);
            drawPositionScale(dc, app, cx, cy, w, h);
        }

        var name = _route.routeName != null ? _route.routeName : "Route";
        var fitted = fitText(dc, name, Graphics.FONT_TINY, w - 30);
        var th = dc.getFontHeight(Graphics.FONT_TINY);
        var topBandH = th + 6;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, 0, w, topBandH);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 3, Graphics.FONT_TINY, fitted, Graphics.TEXT_JUSTIFY_CENTER);

        if (app._mapDebug != null && !app._mapDebug.equals("")) {
            var dbgText = "MAP " + app._mapDebug;
            if (app._lastUrlTail != null && !app._lastUrlTail.equals("")) {
                dbgText = dbgText + " " + app._lastUrlTail;
            }
            var dbgFitted = fitText(dc, dbgText, Graphics.FONT_XTINY, w - 10);
            var dbgH = dc.getFontHeight(Graphics.FONT_XTINY);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.fillRectangle(0, h - dbgH - 4, w, dbgH + 4);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h - dbgH - 2, Graphics.FONT_XTINY, dbgFitted, Graphics.TEXT_JUSTIFY_CENTER);
        }
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

    function drawWaitingScreen(dc as Graphics.Dc, w as Lang.Number, h as Lang.Number) as Void {
        var cx = w / 2;
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

    function drawPolyline(dc as Graphics.Dc, cx as Lang.Number, cy as Lang.Number) as Void {
        var pts = _route.lats.size();
        if (pts < 2) {
            return;
        }
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < pts - 1; i++) {
            var x1 = lonToX(_route.lons[i], cx);
            var y1 = latToY(_route.lats[i], cy);
            var x2 = lonToX(_route.lons[i + 1], cx);
            var y2 = latToY(_route.lats[i + 1], cy);
            dc.drawLine(x1, y1, x2, y2);
        }
    }

    function drawPolylineMap(dc as Graphics.Dc, app as GarmiandApp, mx as Lang.Number, my as Lang.Number) as Void {
        var pts = _route.lats.size();
        if (pts < 2) {
            return;
        }
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < pts - 1; i++) {
            var x1 = mapLonToX(_route.lons[i], app, mx);
            var y1 = mapLatToY(_route.lats[i], app, my);
            var x2 = mapLonToX(_route.lons[i + 1], app, mx);
            var y2 = mapLatToY(_route.lats[i + 1], app, my);
            dc.drawLine(x1, y1, x2, y2);
        }
    }

    function drawMarkers(dc as Graphics.Dc, cx as Lang.Number, cy as Lang.Number) as Void {
        var cnt = _route.markerLats.size();
        for (var i = 0; i < cnt; i++) {
            var px = lonToX(_route.markerLons[i], cx);
            var py = latToY(_route.markerLats[i], cy);
            drawMarkerAt(dc, px, py, _route.markerTitles[i]);
        }
    }

    function drawMarkersMap(dc as Graphics.Dc, app as GarmiandApp, mx as Lang.Number, my as Lang.Number) as Void {
        var cnt = _route.markerLats.size();
        for (var i = 0; i < cnt; i++) {
            var px = mapLonToX(_route.markerLons[i], app, mx);
            var py = mapLatToY(_route.markerLats[i], app, my);
            drawMarkerAt(dc, px, py, _route.markerTitles[i]);
        }
    }

    function drawMarkerAt(dc as Graphics.Dc, px as Lang.Number, py as Lang.Number, title as Lang.String) as Void {
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(px, py, 4);
        if ("Start".equals(title) || "Finish".equals(title)) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(px + 6, py - 8, Graphics.FONT_TINY, title, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    function drawPositionScale(dc as Graphics.Dc, app as GarmiandApp, cx as Lang.Number, cy as Lang.Number, w as Lang.Number, h as Lang.Number) as Void {
        if (app._currentLat == 0.0f) { return; }
        var px = lonToX(app._currentLon, cx);
        var py = latToY(app._currentLat, cy);
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(px, py, 6);
        if (NavigationCalculator.isOffRoute(_route, app._currentLat, app._currentLon)) {
            drawBanner(dc, cx, h - 28, "OFF ROUTE", Graphics.COLOR_RED);
        }
    }

    function drawPositionMap(dc as Graphics.Dc, app as GarmiandApp, mx as Lang.Number, my as Lang.Number, w as Lang.Number, h as Lang.Number) as Void {
        if (app._currentLat == 0.0f) { return; }
        var px = mapLonToX(app._currentLon, app, mx);
        var py = mapLatToY(app._currentLat, app, my);
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(px, py, 6);
        if (NavigationCalculator.isOffRoute(_route, app._currentLat, app._currentLon)) {
            drawBanner(dc, w / 2, h - 28, "OFF ROUTE", Graphics.COLOR_RED);
        }
    }

    function drawBanner(dc as Graphics.Dc, cx as Lang.Number, cy as Lang.Number, text as Lang.String, color as Lang.Number) as Void {
        var tw = dc.getTextWidthInPixels(text, Graphics.FONT_TINY);
        var th = dc.getFontHeight(Graphics.FONT_TINY);
        var pad = 6;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(cx - tw / 2 - pad, cy - 2, tw + pad * 2, th + 4);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, Graphics.FONT_TINY, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function lonToX(lon as Lang.Float, cx as Lang.Number) as Lang.Number {
        return cx + ((lon - _centerLon) / _scale).toNumber();
    }

    function latToY(lat as Lang.Float, cy as Lang.Number) as Lang.Number {
        return cy - ((lat - _centerLat) / _scale).toNumber();
    }

    function mapLonToX(lon as Lang.Float, app as GarmiandApp, mx as Lang.Number) as Lang.Number {
        var span = app._mapMaxLon - app._mapMinLon;
        if (span == 0.0) { return mx; }
        return mx + ((lon - app._mapMinLon) / span * app._mapWidth).toNumber();
    }

    function mapLatToY(lat as Lang.Float, app as GarmiandApp, my as Lang.Number) as Lang.Number {
        var span = app._mapMaxLat - app._mapMinLat;
        if (span == 0.0) { return my; }
        return my + ((app._mapMaxLat - lat) / span * app._mapHeight).toNumber();
    }

    function zoomIn() as Void {
        _scale = _scale * 0.7f;
    }

    function zoomOut() as Void {
        _scale = _scale * 1.4f;
    }

    function toggleAutoCenter() as Void {
        _autoCenter = !_autoCenter;
        if (!_autoCenter) {
            fitRoute();
        }
    }
}
