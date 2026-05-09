using Toybox.Application as App;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.Position;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

class GarmiandApp extends App.AppBase {
    var _route as RouteData;
    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _gpsTimer as Timer.Timer?;
    var _navView as NavigationView?;
    var _bleChunkAssembler as BleChunkAssembler?;

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
        _navView = view;
        var delegate = new NavigationDelegate(_route, view);
        return [view, delegate];
    }

    function onGpsPosition(info as Position.Info) as Void {
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
        System.println("[GPS:" + source + "] lat=" + lat + " lon=" + lon);
        _currentLat = lat;
        _currentLon = lon;
        if (_navView != null) {
            _navView.updateGpsPosition(lat, lon);
        }
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
            if (_navView != null) {
                _navView.applyRoute(_route);
            }
            WatchUi.requestUpdate();
            return;
        }

        if ("tile_session".equals(kind)) {
            handleTileSession(dict);
            return;
        }

        if ("tile_chunk".equals(kind)) {
            handleTileChunk(dict);
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
            if (_navView != null) {
                _navView.applyRoute(_route);
            }
            System.println("[App] route_full loaded: " + _route.lats.size() + " pts, " + _route.markerLats.size() + " markers");
            WatchUi.requestUpdate();
            return;
        }
    }

    var _pendingBundleId as Lang.String?;

    function handleTileSession(dict as Lang.Dictionary) as Void {
        var bundleId = dict["bundle_id"] as Lang.String;
        var url = dict["download_url"] as Lang.String;
        if (bundleId == null || url == null) {
            System.println("[Tiles] tile_session missing fields");
            return;
        }
        System.println("[Tiles] HTTPS bundle " + bundleId + " <- " + url);
        _pendingBundleId = bundleId;
        Communications.makeWebRequest(
            url,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
            },
            method(:onBundleResponse)
        );
    }

    function onBundleResponse(responseCode as Lang.Number, data as Lang.Object) as Void {
        var bundleId = _pendingBundleId;
        _pendingBundleId = null;
        if (responseCode != 200) {
            System.println("[Tiles] bundle fetch failed code=" + responseCode);
            return;
        }
        if (bundleId == null) {
            System.println("[Tiles] response without pending id");
            return;
        }
        if (!(data instanceof Lang.String)) {
            System.println("[Tiles] response not a string: " + data);
            return;
        }
        var blob;
        try {
            blob = StringUtil.convertEncodedString(data as Lang.String, {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_BASE64,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
            }) as Lang.ByteArray;
        } catch (e) {
            System.println("[Tiles] base64 decode failed: " + e.getErrorMessage());
            return;
        }
        System.println("[Tiles] decoded bundle " + bundleId + " size=" + blob.size());
        if (TileDecoder.persist(bundleId as Lang.String, blob)) {
            if (_navView != null) {
                _navView.setBundleId(bundleId);
            }
        }
    }

    function handleTileChunk(dict as Lang.Dictionary) as Void {
        // Stage 9 will assemble chunks into a bundle blob and persist.
        if (_bleChunkAssembler == null) {
            _bleChunkAssembler = new BleChunkAssembler();
        }
        var assembled = (_bleChunkAssembler as BleChunkAssembler).accept(dict);
        if (assembled != null && _navView != null) {
            _navView.setBundleId(assembled);
        }
    }
}

