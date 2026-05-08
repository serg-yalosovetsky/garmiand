using Toybox.Application as App;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

class GarmiandApp extends App.AppBase {
    var _route as RouteData;
    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _gpsTimer as Timer.Timer?;

    function initialize() {
        AppBase.initialize();
        _route = new RouteData();
        _currentLat = 0.0f;
        _currentLon = 0.0f;
    }

    function onStart(state) {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));

        System.println("[GPS] enableLocationEvents(CONTINUOUS) at AppBase");
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onGpsPosition));

        _gpsTimer = new Timer.Timer();
        _gpsTimer.start(method(:pollGps), 1000, true);
    }

    function onStop(state) {
        if (_gpsTimer != null) {
            _gpsTimer.stop();
            _gpsTimer = null;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onGpsPosition));
    }

    function getInitialView() {
        var view = new NavigationView(_route);
        var delegate = new NavigationDelegate(_route, view);
        return [view, delegate];
    }

    function onGpsPosition(info as Position.Info) as Void {
        System.println("[GPS] onGpsPosition fired, accuracy=" + info.accuracy);
        applyPositionInfo(info, "callback");
    }

    function pollGps() as Void {
        var info = Position.getInfo();
        applyPositionInfo(info, "poll");
    }

    function applyPositionInfo(info as Position.Info, source as Lang.String) as Void {
        if (info.accuracy == Position.QUALITY_NOT_AVAILABLE) {
            return;
        }
        var pos = info.position;
        if (pos == null) {
            return;
        }
        var coords = pos.toDegrees();
        var lat = coords[0].toFloat();
        var lon = coords[1].toFloat();
        if (lat == _currentLat && lon == _currentLon) {
            return;
        }
        System.println("[GPS:" + source + "] lat=" + lat + " lon=" + lon + " acc=" + info.accuracy);
        _currentLat = lat;
        _currentLon = lon;
        WatchUi.requestUpdate();
    }

    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        var data = msg.data;
        if (!(data instanceof Lang.Dictionary)) {
            return;
        }
        var dict = data as Lang.Dictionary;
        if (!dict.hasKey("kind")) {
            return;
        }

        var kind = dict["kind"];
        System.println("[PhoneMsg] kind=" + kind);

        if ("sync_start".equals(kind)) {
            _route.reset();
            _route.routeId = dict["route_id"];
            _route.routeName = dict["route_name"];
            _route.expectedChunkCount = dict["chunk_count"];
            WatchUi.requestUpdate();
            return;
        }

        if ("route_chunk".equals(kind)) {
            _route.addChunk(dict["lats"], dict["lons"]);
            WatchUi.requestUpdate();
            return;
        }

        if ("markers".equals(kind)) {
            var rawMarkers = dict["markers"];
            if (rawMarkers instanceof Lang.Array) {
                _route.setMarkers(rawMarkers as Lang.Array);
                WatchUi.requestUpdate();
            }
            return;
        }

        if ("sync_finish".equals(kind)) {
            _route.isComplete = true;
            WatchUi.requestUpdate();
            return;
        }

        if ("route_full".equals(kind)) {
            _route.reset();
            _route.routeId = dict["route_id"];
            _route.routeName = dict["route_name"];
            _route.expectedChunkCount = 1;
            _route.addChunk(dict["lats"], dict["lons"]);
            var rawMarkers = dict["markers"];
            if (rawMarkers instanceof Lang.Array) {
                _route.setMarkers(rawMarkers as Lang.Array);
            }
            _route.isComplete = true;
            System.println("[App] route_full loaded: " + _route.lats.size() + " pts, " + _route.markerLats.size() + " markers");
            WatchUi.requestUpdate();
            return;
        }
    }
}
