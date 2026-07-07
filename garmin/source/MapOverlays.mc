using Toybox.Graphics;
using Toybox.Lang;
using Toybox.System;

// Stateless drawing helpers pulled out of NavigationView to keep that file an
// orchestrator. Every method takes the live NavigationView (`view`) and reads
// its public state / calls its projectPoint(); nothing here holds state. The
// route/waypoint/position/GPS overlays are drawn on top of every map mode.
class MapOverlays {

    // Height of the top band. Full (~50px) only while the route name is on
    // screen (5s after applyRoute); compact (~26px) otherwise so the map shows.
    static function topBandH(dc as Graphics.Dc, view as NavigationView) as Lang.Number {
        if (view._routeNameUntilMs > 0) {
            return dc.getFontHeight(Graphics.FONT_TINY) + 26;
        }
        return dc.getFontHeight(Graphics.FONT_XTINY) + 10;
    }

    static function drawTopBand(dc as Graphics.Dc, view as NavigationView) as Void {
        var w = dc.getWidth();
        var bh = topBandH(dc, view);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, 0, w, bh);

        // Mode line at y=4 — only in TILES mode
        if (view._mapMode == BG_MODE_TILES) {
            var im = (view._interactMode == INTERACT_PAN_NS) ? "NS"
                   : (view._interactMode == INTERACT_PAN_WE) ? "WE"
                   : (view._interactMode == INTERACT_JUMP)   ? "JMP" : "ZOOM";
            var have = view._tiles.hasTiles();
            var dec = view._tiles.isDecoding();
            var zStatus = dec ? "dec" : (have ? "ok" : "-");
            // z<osm> is the tile-set bucket (discrete 13/15/17); x<factor> is the
            // live zoom the buttons control — shown so the badge reflects the real
            // zoom, not just the static tile level.
            var modeLabel = im + " z" + view._activeOsmZoom.toString()
                + " x" + view._zoomFactor.format("%.1f") + " " + zStatus;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, 4, Graphics.FONT_XTINY, modeLabel, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Route name — visible for 5 s after applyRoute()
        if (view._routeNameUntilMs > 0) {
            var name = view._route.routeName != null ? view._route.routeName : "Route";
            var fitted = fitText(dc, name, Graphics.FONT_TINY, w - 80);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, 20, Graphics.FONT_TINY, fitted, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // BLE indicator. When band is compact (no route name), y=20 keeps us inside the
        // circle (boundary at y=20 is x≈199; dot centre at w-70=190 + r5 = 195 < 199).
        // When full band, original w-38 at y≈46 is safe (boundary ≈229 there).
        var showName = view._routeNameUntilMs > 0;
        var dotX = showName ? (w - 38) : (w - 70);
        var dotY = showName ? (bh - 4) : 20;
        if (view._onlineMode) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(dotX, dotY, 5);
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(dotX, dotY, 5);
            dc.drawLine(dotX - 4, dotY - 4, dotX + 4, dotY + 4);
        }
    }

    // Yellow band under the title showing the most recent debug message.
    static function drawDebugLine(dc as Graphics.Dc, view as NavigationView) as Void {
        if (view._debugCurrent == null) { return; }
        var w = dc.getWidth();
        var bandH = topBandH(dc, view);
        var th = dc.getFontHeight(Graphics.FONT_XTINY);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, bandH, w, th + 4);
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        var queued = view._debugQueue.size();
        var suffix = queued > 0 ? "  +" + queued : "";
        dc.drawText(w / 2, bandH + 2, Graphics.FONT_XTINY, (view._debugCurrent as Lang.String) + suffix, Graphics.TEXT_JUSTIFY_CENTER);
    }

    static function drawWaitingScreen(dc as Graphics.Dc, view as NavigationView) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h / 2 - 25, Graphics.FONT_MEDIUM, "Garmiand", Graphics.TEXT_JUSTIFY_CENTER);
        var statusText;
        if (view._route.expectedChunkCount > 0) {
            var pct = (view._route.receivedChunkCount * 100 / view._route.expectedChunkCount).toString() + "%";
            statusText = "Syncing " + pct;
        } else {
            statusText = "Waiting...";
        }
        dc.drawText(cx, h / 2 + 10, Graphics.FONT_SMALL, statusText, Graphics.TEXT_JUSTIFY_CENTER);
        var vth = dc.getFontHeight(Graphics.FONT_XTINY);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 4) / 5 - vth / 2, Graphics.FONT_XTINY, "v " + APP_VERSION, Graphics.TEXT_JUSTIFY_CENTER);
        drawDebugLine(dc, view);
    }

    static function drawPolyline(dc as Graphics.Dc, view as NavigationView) as Void {
        var pts = view._route.lats.size();
        if (pts < 2) {
            return;
        }
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        var prev = view.projectPoint(view._route.lats[0], view._route.lons[0]);
        for (var i = 1; i < pts; i++) {
            var cur = view.projectPoint(view._route.lats[i], view._route.lons[i]);
            if (prev != null && cur != null) {
                dc.drawLine(prev[0], prev[1], cur[0], cur[1]);
            }
            prev = cur;
        }
    }

    static function drawWaypoints(dc as Graphics.Dc, view as NavigationView) as Void {
        var cnt = view._route.markerLats.size();
        for (var i = 0; i < cnt; i++) {
            var pt = view.projectPoint(view._route.markerLats[i], view._route.markerLons[i]);
            if (pt == null) { continue; }
            var x = pt[0];
            var y = pt[1];
            var title = view._route.markerTitles[i];
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

    static function drawPosition(dc as Graphics.Dc, view as NavigationView) as Void {
        if (view._currentLat == 0.0f && view._currentLon == 0.0f) {
            return;
        }
        var pt = view.projectPoint(view._currentLat, view._currentLon);
        if (pt == null) { return; }
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(pt[0], pt[1], 6);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(pt[0], pt[1], 6);
    }

    static function drawOffRoute(dc as Graphics.Dc, view as NavigationView) as Void {
        if (!view._isOffRoute) { return; }
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

    static function fitText(dc as Graphics.Dc, text as Lang.String, font as Graphics.FontType, maxW as Lang.Number) as Lang.String {
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
}
