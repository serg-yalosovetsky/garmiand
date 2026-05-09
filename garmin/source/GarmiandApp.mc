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
    var _onlineMode as Lang.Boolean;

    function initialize() {
        AppBase.initialize();
        _route = new RouteData();
        _currentLat = 0.0f;
        _currentLon = 0.0f;
        _onlineMode = readOnlineModeProperty();
    }

    function readOnlineModeProperty() as Lang.Boolean {
        try {
            var v = App.Properties.getValue("online_mode");
            if (v instanceof Lang.Boolean) { return v as Lang.Boolean; }
        } catch (e) {}
        return true;
    }

    function toggleOnlineMode() as Void {
        _onlineMode = !_onlineMode;
        try {
            App.Properties.setValue("online_mode", _onlineMode);
        } catch (e) {}
        System.println("[App] onlineMode=" + _onlineMode);
        if (_navView != null) {
            (_navView as NavigationView).setOnlineMode(_onlineMode);
        }
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
        view.setOnlineMode(_onlineMode);
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
    var _pendingBundleUrl as Lang.String?;

    function handleTileSession(dict as Lang.Dictionary) as Void {
        var bundleId = dict["bundle_id"] as Lang.String;
        var url = dict["download_url"] as Lang.String;
        if (bundleId == null || url == null) {
            System.println("[Tiles] tile_session missing fields");
            return;
        }
        if (!_onlineMode) {
            System.println("[Tiles] offline mode — skip download, use cached bundle=" + bundleId);
            if (_navView != null) {
                (_navView as NavigationView).setFetchStatus("offline mode");
                (_navView as NavigationView).setBundleId(bundleId);
            }
            return;
        }
        System.println("[Tiles] HTTPS bundle " + bundleId + " <- " + url);
        _pendingBundleId = bundleId;
        _pendingBundleUrl = url;
        if (_navView != null) {
            (_navView as NavigationView).setFetchStatus("fetching…");
        }
        Communications.makeWebRequest(
            url,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
                :headers => {
                    "ngrok-skip-browser-warning" => "true",
                    "Accept" => "text/plain",
                },
            },
            method(:onBundleResponse)
        );
    }

    function onBundleResponse(responseCode as Lang.Number, data as Lang.Dictionary or Lang.String or Null) as Void {
        var bundleId = _pendingBundleId;
        var url = _pendingBundleUrl;
        _pendingBundleId = null;
        _pendingBundleUrl = null;
        if (responseCode != 200) {
            System.println("[Tiles] bundle fetch failed code=" + responseCode + " url=" + url);
            if (_navView != null) {
                (_navView as NavigationView).setFetchStatus("fail code=" + responseCode);
            }
            return;
        }
        if (bundleId == null) {
            System.println("[Tiles] response without pending id");
            return;
        }
        if (!(data instanceof Lang.String)) {
            System.println("[Tiles] response not a string: " + data);
            if (_navView != null) {
                (_navView as NavigationView).setFetchStatus("bad response type");
            }
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
            if (_navView != null) {
                (_navView as NavigationView).setFetchStatus("base64 fail");
            }
            return;
        }
        System.println("[Tiles] decoded bundle " + bundleId + " size=" + blob.size());
        if (_navView != null) {
            (_navView as NavigationView).setFetchStatus("ok " + blob.size() + "B");
        }
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

