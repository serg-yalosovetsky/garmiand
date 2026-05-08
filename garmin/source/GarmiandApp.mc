using Toybox.Application as App;
using Toybox.Communications;
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

    function onPosition(lat, lon) {
        _currentLat = lat;
        _currentLon = lon;
    }

    function onPhoneMessage(msg) {
        if (msg == null || !msg.hasKey("kind")) {
            return;
        }

        var kind = msg["kind"];

        if ("sync_start".equals(kind)) {
            _route.reset();
            _route.routeId = msg["route_id"];
            _route.routeName = msg["route_name"];
            _route.expectedChunkCount = msg["chunk_count"];
            WatchUi.requestUpdate();
            return;
        }

        if ("route_chunk".equals(kind)) {
            _route.addChunk(msg["lats"], msg["lons"]);
            WatchUi.requestUpdate();
            return;
        }

        if ("markers".equals(kind)) {
            _route.setMarkers(msg["markers"]);
            return;
        }

        if ("sync_finish".equals(kind)) {
            _route.isComplete = true;
            WatchUi.requestUpdate();
            return;
        }
    }
}
