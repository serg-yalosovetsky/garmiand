using Toybox.Application as App;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.Position;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Global helper: route a message into the on-screen debug queue if the
// view exists, otherwise just println. Lets non-View code (TileDecoder,
// BleChunkAssembler) surface progress without a direct view reference.
function appLog(msg as Lang.String) as Void {
    System.println("[DBG] " + msg);
    var app = App.getApp();
    if (app instanceof GarmiandApp) {
        var v = (app as GarmiandApp).getNavView();
        if (v != null) {
            (v as NavigationView).pushDebug(msg);
        }
    }
}

// ~10 KB raw → ~13.3 KB base64; stays well inside the CIQ TEXT_PLAIN buffer
const DL_CHUNK_SIZE = 10 * 1024;

class GarmiandApp extends App.AppBase {
    var _route as RouteData;
    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _gpsTimer as Timer.Timer?;
    var _navView as NavigationView?;
    var _bleChunkAssembler as BleChunkAssembler?;
    var _onlineMode as Lang.Boolean;
    // chunked HTTPS download state
    var _dlBuffer as Lang.ByteArray?;
    var _dlOffset as Lang.Number;
    var _dlTotal as Lang.Number;

    function initialize() {
        AppBase.initialize();
        _route = new RouteData();
        _currentLat = 0.0f;
        _currentLon = 0.0f;
        _onlineMode = readOnlineModeProperty();
        _dlBuffer = null;
        _dlOffset = 0;
        _dlTotal = 0;
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
        view.pushDebug("App started, online=" + _onlineMode);
        return [view, delegate];
    }

    function getNavView() as NavigationView? {
        return _navView;
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
            appLog("RX sync_start");
            _route.reset();
            _route.routeId = dict["route_id"];
            _route.routeName = dict["route_name"];
            _route.expectedChunkCount = dict["chunk_count"];
            WatchUi.requestUpdate();
            return;
        }

        if ("route_chunk".equals(kind)) {
            var lats = dict["lats"];
            var n = (lats instanceof Lang.Array) ? (lats as Lang.Array).size() : 0;
            appLog("RX route_chunk pts=" + n);
            _route.addChunk(dict["lats"], dict["lons"]);
            WatchUi.requestUpdate();
            return;
        }

        if ("markers".equals(kind)) {
            var rawMarkers = dict["markers"];
            if (rawMarkers instanceof Lang.Array) {
                appLog("RX markers n=" + (rawMarkers as Lang.Array).size());
                _route.setMarkers(rawMarkers as Lang.Array);
                WatchUi.requestUpdate();
            } else {
                appLog("RX markers (bad type)");
            }
            return;
        }

        if ("sync_finish".equals(kind)) {
            appLog("RX sync_finish pts=" + _route.lats.size());
            _route.isComplete = true;
            if (_navView != null) {
                _navView.applyRoute(_route);
                appLog("route applied");
                logFreeMem("after sync_finish");
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
            appLog("RX route_full");
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
            appLog("route_full pts=" + _route.lats.size());
            WatchUi.requestUpdate();
            return;
        }

        appLog("RX unknown kind=" + kind);
    }

    function logFreeMem(label as Lang.String) as Void {
        try {
            var stats = System.getSystemStats();
            appLog(label + " mem free=" + stats.freeMemory + " used=" + stats.usedMemory);
        } catch (e) {
            appLog(label + " mem stats EX: " + e.getErrorMessage());
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
        if (_navView != null) {
            (_navView as NavigationView).pushDebug("RX tile_session " + bundleId.substring(0, 8));
        }
        if (!_onlineMode) {
            System.println("[Tiles] offline mode — skip download, use cached bundle=" + bundleId);
            if (_navView != null) {
                (_navView as NavigationView).pushDebug("offline mode — skip GET");
                (_navView as NavigationView).setBundleId(bundleId);
            }
            return;
        }
        var totalBytes = dict["total_bytes"];
        _dlTotal = (totalBytes instanceof Lang.Number) ? (totalBytes as Lang.Number) : 0;
        System.println("[Tiles] HTTPS bundle " + bundleId + " <- " + url + " total=" + _dlTotal);
        _pendingBundleId = bundleId;
        _pendingBundleUrl = url;
        _dlOffset = 0;
        _dlBuffer = new [0]b;
        appLog("HTTPS chunk DL start totalB=" + _dlTotal);
        Communications.makeWebRequest(
            url + "/chunk?offset=0&size=" + DL_CHUNK_SIZE,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
                :headers => {
                    "ngrok-skip-browser-warning" => "true",
                    "Accept" => "text/plain",
                },
            },
            method(:onBundleChunkResponse)
        );
    }

    function onBundleChunkResponse(responseCode as Lang.Number, data as Lang.Dictionary or Lang.String or Null) as Void {
        if (responseCode != 200) {
            System.println("[Tiles] chunk fetch failed code=" + responseCode);
            appLog("HTTPS chunk fail code=" + responseCode);
            _pendingBundleId = null;
            _pendingBundleUrl = null;
            _dlBuffer = null;
            _dlOffset = 0;
            _dlTotal = 0;
            return;
        }
        if (!(data instanceof Lang.String)) {
            appLog("HTTPS chunk bad type");
            _pendingBundleId = null;
            _pendingBundleUrl = null;
            _dlBuffer = null;
            return;
        }
        var chunk;
        try {
            chunk = StringUtil.convertEncodedString(data as Lang.String, {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_BASE64,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
            }) as Lang.ByteArray;
        } catch (e) {
            appLog("chunk b64 FAIL: " + e.getErrorMessage());
            _pendingBundleId = null;
            _pendingBundleUrl = null;
            _dlBuffer = null;
            return;
        }
        var chunkSize = chunk.size();
        if (_dlBuffer == null) {
            appLog("HTTPS chunk arrived but no buffer");
            return;
        }
        (_dlBuffer as Lang.ByteArray).addAll(chunk);
        _dlOffset += chunkSize;
        appLog("chunk +" + chunkSize + "B total=" + _dlOffset + "/" + _dlTotal);

        if (_dlOffset >= _dlTotal || chunkSize < DL_CHUNK_SIZE) {
            // all chunks received
            var bundleId = _pendingBundleId;
            var blob = _dlBuffer as Lang.ByteArray;
            _pendingBundleId = null;
            _pendingBundleUrl = null;
            _dlBuffer = null;
            _dlOffset = 0;
            _dlTotal = 0;
            appLog("HTTPS done " + blob.size() + "B");
            if (TileDecoder.persist(bundleId as Lang.String, blob)) {
                appLog("persist ok");
                if (_navView != null) {
                    _navView.setBundleId(bundleId as Lang.String);
                }
            } else {
                appLog("persist FAIL");
            }
        } else {
            // fetch next chunk
            var nextUrl = (_pendingBundleUrl as Lang.String) + "/chunk?offset=" + _dlOffset + "&size=" + DL_CHUNK_SIZE;
            Communications.makeWebRequest(
                nextUrl,
                null,
                {
                    :method => Communications.HTTP_REQUEST_METHOD_GET,
                    :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
                    :headers => {
                        "ngrok-skip-browser-warning" => "true",
                        "Accept" => "text/plain",
                    },
                },
                method(:onBundleChunkResponse)
            );
        }
    }

    function handleTileChunk(dict as Lang.Dictionary) as Void {
        if (_bleChunkAssembler == null) {
            _bleChunkAssembler = new BleChunkAssembler();
            appLog("BLE assembler new");
        }
        var i = dict["i"];
        var n = dict["n"];
        var p = dict["p"];
        var pSize = (p instanceof Lang.ByteArray) ? (p as Lang.ByteArray).size() : -1;
        if (i != null && n != null) {
            appLog("BLE chunk " + i + "/" + n + " (" + pSize + "B)");
        }
        var result = (_bleChunkAssembler as BleChunkAssembler).accept(dict);
        if (result == null) {
            return;
        }
        var assembledId = result[0];
        var blob = result[1];
        var err = result[2];
        if (err != null) {
            appLog("BLE " + (err as Lang.String));
            return;
        }
        var blobSize = (blob as Lang.ByteArray).size();
        appLog("BLE assembled " + blobSize + "B");
        logFreeMem("pre-persist");
        var ok = false;
        try {
            appLog("persist try " + blobSize + "B");
            ok = TileDecoder.persist(assembledId as Lang.String, blob as Lang.ByteArray);
        } catch (e) {
            appLog("persist EX: " + e.getErrorMessage());
            return;
        }
        if (!ok) {
            appLog("persist FAIL (Storage limit?)");
            return;
        }
        appLog("persist ok");
        logFreeMem("post-persist");
        if (_navView != null) {
            _navView.setBundleId(assembledId as Lang.String);
        }
    }
}

