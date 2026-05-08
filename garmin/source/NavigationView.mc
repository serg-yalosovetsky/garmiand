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

        if (_lastFittedSize != _route.lats.size()) {
            fitRoute();
            _lastFittedSize = _route.lats.size();
        }

        var app = App.getApp() as GarmiandApp;
        var posLat = app._currentLat;
        var posLon = app._currentLon;

        if (_autoCenter && posLat != 0.0f) {
            _centerLat = posLat;
            _centerLon = posLon;
        }

        drawPolyline(dc, cx, cy);
        drawMarkers(dc, cx, cy);

        if (posLat != 0.0f) {
            var px = lonToX(posLon, cx);
            var py = latToY(posLat, cy);
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(px, py, 6);

            if (NavigationCalculator.isOffRoute(_route, posLat, posLon)) {
                dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, h - 30, Graphics.FONT_TINY, "OFF ROUTE", Graphics.TEXT_JUSTIFY_CENTER);
            }
        }

        var name = _route.routeName != null ? _route.routeName : "Route";
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 5, Graphics.FONT_TINY, name, Graphics.TEXT_JUSTIFY_CENTER);
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

    function drawMarkers(dc as Graphics.Dc, cx as Lang.Number, cy as Lang.Number) as Void {
        var cnt = _route.markerLats.size();
        for (var i = 0; i < cnt; i++) {
            var mx = lonToX(_route.markerLons[i], cx);
            var my = latToY(_route.markerLats[i], cy);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(mx, my, 4);
            var title = _route.markerTitles[i];
            if ("Start".equals(title) || "Finish".equals(title)) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(mx + 6, my - 8, Graphics.FONT_TINY, title, Graphics.TEXT_JUSTIFY_LEFT);
            }
        }
    }

    function lonToX(lon as Lang.Float, cx as Lang.Number) as Lang.Number {
        return cx + ((lon - _centerLon) / _scale).toNumber();
    }

    function latToY(lat as Lang.Float, cy as Lang.Number) as Lang.Number {
        return cy - ((lat - _centerLat) / _scale).toNumber();
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
