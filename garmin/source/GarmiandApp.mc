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
    var app = App.getApp();
    if (app instanceof GarmiandApp) {
        var v = (app as GarmiandApp).getNavView();
        if (v != null) {
            (v as NavigationView).pushDebug(msg); // pushDebug calls System.println itself
            return;
        }
    }
    System.println("[DBG] " + msg); // fallback: no view yet
}

// ~10 KB raw → ~13.3 KB base64; stays well inside the CIQ TEXT_PLAIN buffer
const DL_CHUNK_SIZE = 10 * 1024;

class NullConnectionListener extends Communications.ConnectionListener {
    function initialize() { Communications.ConnectionListener.initialize(); }
    function onComplete() as Void {}
    function onError() as Void {}
}

class GarmiandApp extends App.AppBase {
    var _route as RouteData;
    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _gpsTimer as Timer.Timer?;
    var _navView as NavigationView?;
    var _bleChunkAssembler as BleChunkAssembler?;
    var _bleStallTimer as Timer.Timer?;
    var _onlineMode as Lang.Boolean;
    // chunked HTTPS download state
    var _dlBuffer as Lang.ByteArray?;
    var _dlOffset as Lang.Number;
    var _dlTotal as Lang.Number;
    // BLE chunk dicts deferred from onPhoneMessage to onUpdate (watchdog budget)
    var _pendingTileChunkDicts as Lang.Array<Lang.Dictionary>;
    // Blob ready to persist — deferred from HTTP callback to onUpdate (watchdog budget)
    var _pendingPersistId as Lang.String?;
    var _pendingPersistBlob as Lang.ByteArray?;

    function initialize() {
        AppBase.initialize();
        _route = new RouteData();
        _currentLat = 0.0f;
        _currentLon = 0.0f;
        _onlineMode = readOnlineModeProperty();
        _dlBuffer = null;
        _dlOffset = 0;
        _dlTotal = 0;
        _pendingTileChunkDicts = [] as Lang.Array<Lang.Dictionary>;
        _pendingPersistId = null;
        _pendingPersistBlob = null;
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

        loadSavedRoute();

        // Restore any in-progress BLE bundle transfer from App.Storage.
        var restoredAsm = BleChunkAssembler.loadWip();
        if (restoredAsm != null) {
            _bleChunkAssembler = restoredAsm;
            var prog = (restoredAsm as BleChunkAssembler).progress();
            System.println("[BLE] WIP restored " + prog[0] + "/" + prog[1] + " chunks");
        }

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
        disarmBleStallTimer();
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onGpsPosition));
    }

    function getInitialView() {
        var view = new NavigationView(_route);
        _navView = view;
        view.setOnlineMode(_onlineMode);
        if (_route.isComplete) {
            view.applyRoute(_route);
            view.pushDebug("restored route pts=" + _route.lats.size());
        }
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
            saveRoute();
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

        if ("ble_bundle_start".equals(kind)) {
            handleBleBundleStart(dict);
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
            saveRoute();
            appLog("route_full pts=" + _route.lats.size());
            WatchUi.requestUpdate();
            return;
        }

        appLog("RX unknown kind=" + kind);
    }

    function saveRoute() as Void {
        if (!_route.isComplete) { return; }
        try {
            App.Storage.setValue("route_id",     _route.routeId);
            App.Storage.setValue("route_name",   _route.routeName);
            App.Storage.setValue("route_lats",   _route.lats);
            App.Storage.setValue("route_lons",   _route.lons);
            App.Storage.setValue("route_mlats",  _route.markerLats);
            App.Storage.setValue("route_mlons",  _route.markerLons);
            App.Storage.setValue("route_mtitles",_route.markerTitles);
            System.println("[Route] saved " + _route.lats.size() + " pts");
        } catch (e) {
            System.println("[Route] save EX: " + e.getErrorMessage());
        }
    }

    function loadSavedRoute() as Void {
        try {
            var latsV = App.Storage.getValue("route_lats");
            var lonsV = App.Storage.getValue("route_lons");
            if (!(latsV instanceof Lang.Array) || !(lonsV instanceof Lang.Array)) {
                System.println("[Route] no saved route in storage");
                return;
            }
            _route.reset();
            var ridV = App.Storage.getValue("route_id");
            _route.routeId = (ridV instanceof Lang.String) ? (ridV as Lang.String) : null;
            var rnameV = App.Storage.getValue("route_name");
            _route.routeName = (rnameV instanceof Lang.String) ? (rnameV as Lang.String) : null;
            var latsA = latsV as Lang.Array;
            var lonsA = lonsV as Lang.Array;
            var n = latsA.size();
            for (var i = 0; i < n; i++) {
                _route.lats.add((latsA[i] as Lang.Numeric).toFloat());
                _route.lons.add((lonsA[i] as Lang.Numeric).toFloat());
            }
            var mlaV = App.Storage.getValue("route_mlats");
            var mloV = App.Storage.getValue("route_mlons");
            var mtiV = App.Storage.getValue("route_mtitles");
            if (mlaV instanceof Lang.Array && mloV instanceof Lang.Array && mtiV instanceof Lang.Array) {
                var mlaA = mlaV as Lang.Array;
                var mloA = mloV as Lang.Array;
                var mtiA = mtiV as Lang.Array;
                var mn = mlaA.size();
                for (var i = 0; i < mn; i++) {
                    _route.markerLats.add((mlaA[i] as Lang.Numeric).toFloat());
                    _route.markerLons.add((mloA[i] as Lang.Numeric).toFloat());
                    _route.markerTitles.add(mtiA[i] as Lang.String);
                    _route.markerIds.add("");
                }
            }
            _route.expectedChunkCount = 1;
            _route.receivedChunkCount = 1;
            _route.isComplete = true;
            System.println("[Route] restored " + n + " pts from storage");
        } catch (e) {
            System.println("[Route] load EX: " + e.getErrorMessage());
        }
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
        // Skip download if bundle already in Storage (same route re-synced)
        if (TileDecoder.exists(bundleId)) {
            System.println("[Tiles] bundle already in Storage — skip download " + bundleId.substring(0, 8));
            if (_navView != null) {
                (_navView as NavigationView).pushDebug("cached " + bundleId.substring(0, 8));
                (_navView as NavigationView).setBundleId(bundleId);
            }
            return;
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
        // single contiguous allocation avoids heap fragmentation from repeated addAll
        _dlBuffer = (_dlTotal > 0) ? new [_dlTotal]b : new [0]b;
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
        var buf = _dlBuffer as Lang.ByteArray;
        if (_dlTotal > 0) {
            // write into pre-allocated buffer at the correct offset (no realloc)
            for (var ci = 0; ci < chunkSize; ci++) {
                buf[_dlOffset + ci] = chunk[ci];
            }
        } else {
            buf.addAll(chunk);
        }
        _dlOffset += chunkSize;
        appLog("chunk +" + chunkSize + "B total=" + _dlOffset + "/" + _dlTotal);

        if (_dlOffset >= _dlTotal || chunkSize < DL_CHUNK_SIZE) {
            // All HTTP chunks received. Defer persist to onUpdate — HTTP callbacks
            // have a shorter watchdog than onUpdate; Storage.setValue N times here
            // would trip it on device even if it works in the simulator.
            appLog("HTTPS done " + (_dlBuffer as Lang.ByteArray).size() + "B — queued for persist");
            _pendingPersistId = _pendingBundleId;
            _pendingPersistBlob = _dlBuffer;
            _pendingBundleId = null;
            _pendingBundleUrl = null;
            _dlBuffer = null;
            _dlOffset = 0;
            _dlTotal = 0;
            WatchUi.requestUpdate();
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

    function armBleStallTimer() as Void {
        if (_bleStallTimer != null) {
            (_bleStallTimer as Timer.Timer).stop();
            _bleStallTimer = null;
        }
        var t = new Timer.Timer();
        t.start(method(:onBleStallTimeout), 10000, false);
        _bleStallTimer = t;
    }

    function disarmBleStallTimer() as Void {
        if (_bleStallTimer != null) {
            (_bleStallTimer as Timer.Timer).stop();
            _bleStallTimer = null;
        }
    }

    function onBleStallTimeout() as Void {
        _bleStallTimer = null;
        if (_bleChunkAssembler == null) {
            return;
        }
        var asm = _bleChunkAssembler as BleChunkAssembler;
        var prog = asm.progress();
        var received = (prog[0] as Lang.Number).toNumber();
        var total = (prog[1] as Lang.Number).toNumber();
        var missing = asm.getMissingIndices();
        appLog("BLE STALL " + received + "/" + total + " missing=" + missing.toString());
        logFreeMem("BLE stall");
        // Free the partially-assembled chunk memory to prevent OOM crash
        _bleChunkAssembler = null;
        appLog("BLE assembler reset after stall");
    }

    // Called from onPhoneMessage — must return fast (tight watchdog budget).
    // Defers the byte-copy work to processPendingTileChunk() run from onUpdate.
    function handleTileChunk(dict as Lang.Dictionary) as Void {
        var i = dict["i"];
        var n = dict["n"];
        var p = dict["p"];
        var pSize = (p instanceof Lang.ByteArray) ? (p as Lang.ByteArray).size() : -1;
        if (i != null && n != null) {
            appLog("BLE chunk " + i + "/" + n + " (" + pSize + "B) queued");
        }
        _pendingTileChunkDicts.add(dict);
        WatchUi.requestUpdate();
    }

    // Called from NavigationView.onUpdate() — full watchdog budget available.
    // Drains one queued tile_chunk dict per frame and calls requestUpdate()
    // again if more remain, so each chunk gets its own frame budget.
    function processPendingTileChunk() as Void {
        if (_pendingTileChunkDicts.size() == 0) {
            return;
        }
        var dict = _pendingTileChunkDicts[0] as Lang.Dictionary;
        _pendingTileChunkDicts.remove(dict);

        if (_bleChunkAssembler == null) {
            _bleChunkAssembler = new BleChunkAssembler();
            appLog("BLE assembler new");
        }
        var result = (_bleChunkAssembler as BleChunkAssembler).accept(dict);
        if (result == null) {
            armBleStallTimer();
            if (_pendingTileChunkDicts.size() > 0) {
                WatchUi.requestUpdate();
            }
            return;
        }
        disarmBleStallTimer();
        var assembledId = result[0];
        var blob = result[1];
        var err = result[2];
        if (err != null) {
            appLog("BLE " + (err as Lang.String));
            return;
        }
        var blobSize = (blob as Lang.ByteArray).size();
        appLog("BLE assembled " + blobSize + "B — queued for persist");
        // Clear WIP storage: assembly is complete, no longer need per-chunk data.
        BleChunkAssembler.clearWip();
        // Defer persist to the next onUpdate frame. Calling persist here would
        // combine ~30k bytecodes (last byte-copy) + 13×Storage.setValue and
        // exceed the watchdog budget on device. processPendingPersist() runs
        // before processPendingTileChunk() in onUpdate, so the next frame is
        // guaranteed to be persist-only with the full watchdog budget.
        _pendingPersistId = assembledId as Lang.String;
        _pendingPersistBlob = blob as Lang.ByteArray;
        WatchUi.requestUpdate();
    }

    // Handles ble_bundle_start from phone: reports WIP received indices back via
    // Communications.transmit() so phone can skip already-received chunks.
    // Called from onPhoneMessage — must return fast (BLE callback watchdog).
    function handleBleBundleStart(dict as Lang.Dictionary) as Void {
        var bundleId = dict["bundle_id"];
        var total = dict["n"];
        if (bundleId == null || total == null) {
            System.println("[BLE] ble_bundle_start missing fields");
            return;
        }
        appLog("RX ble_bundle_start " + (bundleId as Lang.String).substring(0, 8));

        var indices = [] as Lang.Array<Lang.Number>;
        if (_bleChunkAssembler != null) {
            var asm = _bleChunkAssembler as BleChunkAssembler;
            var asmId = asm.getBundleId();
            if (asmId != null && (asmId as Lang.String).equals(bundleId as Lang.String)) {
                indices = asm.getReceivedIndices();
                appLog("BLE WIP n=" + indices.size() + " reporting to phone");
            } else {
                // Different bundle — reset stale WIP
                _bleChunkAssembler = null;
                BleChunkAssembler.clearWip();
                appLog("BLE new bundle — WIP cleared");
            }
        }

        // If no WIP but bundle already fully persisted, report all indices so phone skips them
        if (indices.size() == 0 && TileDecoder.exists(bundleId as Lang.String)) {
            var tot = (total as Lang.Number).toNumber();
            for (var ii = 0; ii < tot; ii++) { indices.add(ii); }
            appLog("BLE bundle already in Storage — skip " + tot + " chunks");
            if (_navView != null) {
                (_navView as NavigationView).setBundleId(bundleId as Lang.String);
            }
        }

        // Transmit WIP report to phone (empty array = start from chunk 0)
        try {
            Communications.transmit(
                {
                    "kind" => "ble_wip_report",
                    "bundle_id" => bundleId,
                    "received_indices" => indices
                } as Lang.Dictionary,
                null,
                new NullConnectionListener()
            );
            System.println("[BLE] transmitted ble_wip_report indices=" + indices.size());
        } catch (e) {
            System.println("[BLE] transmit ble_wip_report failed: " + e.getErrorMessage());
        }
    }

    // Called from NavigationView.onUpdate() — full watchdog budget available.
    // Persists blob queued by onBundleChunkResponse when HTTPS download completes.
    function processPendingPersist() as Void {
        if (_pendingPersistBlob == null) {
            return;
        }
        var bundleId = _pendingPersistId as Lang.String;
        var blob = _pendingPersistBlob as Lang.ByteArray;
        _pendingPersistId = null;
        _pendingPersistBlob = null;
        appLog("persist " + blob.size() + "B");
        logFreeMem("pre-persist");
        var ok = false;
        try {
            ok = TileDecoder.persist(bundleId, blob);
        } catch (e) {
            appLog("persist EX: " + e.getErrorMessage());
            return;
        }
        if (ok) {
            appLog("persist ok");
            logFreeMem("post-persist");
            if (_navView != null) {
                _navView.setBundleId(bundleId);
            }
        } else {
            appLog("persist FAIL");
        }
    }
}

