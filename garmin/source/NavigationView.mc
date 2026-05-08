using Toybox.Graphics;
using Toybox.WatchUi;
using Toybox.Application as App;

class NavigationView extends WatchUi.View {
    var _route;

    var _scale;        // градусы на пиксель
    var _centerLat;
    var _centerLon;
    var _autoCenter;

    function initialize(route) {
        View.initialize();
        _route = route;
        _scale = 0.0001f;
        _centerLat = 0.0f;
        _centerLon = 0.0f;
        _autoCenter = true;
    }

    function onUpdate(dc) {
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

        var app = App.getApp();
        var posLat = app._currentLat;
        var posLon = app._currentLon;

        if (_autoCenter && posLat != 0.0f) {
            _centerLat = posLat;
            _centerLon = posLon;
        } else if (_centerLat == 0.0f && _route.lats.size() > 0) {
            _centerLat = _route.lats[_route.lats.size() / 2];
            _centerLon = _route.lons[_route.lons.size() / 2];
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

    function drawWaitingScreen(dc, w, h) {
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

    function drawPolyline(dc, cx, cy) {
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

    function drawMarkers(dc, cx, cy) {
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

    function lonToX(lon, cx) {
        return cx + ((lon - _centerLon) / _scale).toNumber();
    }

    function latToY(lat, cy) {
        return cy - ((lat - _centerLat) / _scale).toNumber();
    }

    function zoomIn() {
        _scale = _scale * 0.7f;
    }

    function zoomOut() {
        _scale = _scale * 1.4f;
    }

    function toggleAutoCenter() {
        _autoCenter = !_autoCenter;
    }
}
