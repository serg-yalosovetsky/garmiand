using Toybox.Application as App;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.WatchUi;

class GarmiandApp extends App.AppBase {
    var _route;
    var _gpsListener;
    var _currentLat;
    var _currentLon;

    function initialize() {
        AppBase.initialize();
        _route = new RouteData();
        _currentLat = 0.0f;
        _currentLon = 0.0f;
    }

    function onStart(state) {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        _gpsListener = new GpsListener(method(:onPosition));
        _gpsListener.start();
    }

    function onStop(state) {
        if (_gpsListener != null) {
            _gpsListener.stop();
        }
    }

    function getInitialView() {
        var view = new NavigationView(_route);
        var delegate = new NavigationDelegate(_route, view);
        return [view, delegate];
    }

    function onPosition(lat as Lang.Float, lon as Lang.Float) as Void {
        _currentLat = lat;
        _currentLon = lon;
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
            _route.setMarkers(dict["markers"]);
            return;
        }

        if ("sync_finish".equals(kind)) {
            _route.isComplete = true;
            WatchUi.requestUpdate();
            return;
        }
    }
}
