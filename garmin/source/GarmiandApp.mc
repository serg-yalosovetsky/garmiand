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
        var ga = app as GarmiandApp;
        var v = ga.getNavView();
        if (v != null) {
            (v as NavigationView).pushDebug(msg); // pushDebug calls System.println itself
            return;
        }
        ga.enqueueWatchLog(msg); // no view yet — still forward to phone (→ Loki)
    }
    System.println("[DBG] " + msg); // fallback: no view yet
}

// ~10 KB raw → ~13.3 KB base64; stays well inside the CIQ TEXT_PLAIN buffer
const DL_CHUNK_SIZE = 10 * 1024;

// Auto map fetch: ask the phone for a fresh bundle when the user nears the
// edge of the cached one. Deliberately lazy — the CIQ watchdog kills apps
// that burn CPU, so the check runs on every AUTOFETCH_CHECK_EVERY-th GPS tick
// (a handful of float compares), and an actual transmit happens at most once
// per AUTOFETCH_COOLDOWN_MS and never while a transfer/decode is in flight.
const AUTOFETCH_COOLDOWN_MS = 120000;   // ≥2 min between requests
const AUTOFETCH_CHECK_EVERY = 5;        // check every 5th GPS tick (~5 s)
const AUTOFETCH_EDGE_FRACTION = 0.25;   // "near edge" = outer 25% of the bbox

class NullConnectionListener extends Communications.ConnectionListener {
    function initialize() { Communications.ConnectionListener.initialize(); }
    function onComplete() as Void {}
    function onError() as Void {}
}

// Frees the watch-log transmit slot once a batch has been sent (or failed),
// so flushWatchLog() never has more than one transmit in flight.
class LogConnectionListener extends Communications.ConnectionListener {
    function initialize() { Communications.ConnectionListener.initialize(); }
    function onComplete() as Void { notifyDone(); }
    function onError() as Void { notifyDone(); }
    function notifyDone() as Void {
        var app = App.getApp();
        if (app instanceof GarmiandApp) { (app as GarmiandApp).onLogTxDone(); }
    }
}

class GarmiandApp extends App.AppBase {
    var _route as RouteData;
    var _currentLat as Lang.Float;
    var _currentLon as Lang.Float;
    var _gpsTimer as Timer.Timer?;
    var _navView as NavigationView?;
    var _bleChunkAssembler as BleChunkAssembler?;
    // BLE-stall detection WITHOUT a dedicated timer: the deadline (System.getTimer
    // ms) after which an in-flight transfer is considered stalled. 0 = no active
    // transfer. Checked once per second from pollGps(). A reused one-shot Timer
    // here fired immediately on re-arm (CIQ quirk) and reset the assembler every
    // few ms, so the bundle never finished — hence the timestamp approach.
    var _bleStallDeadlineMs as Lang.Number;
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
    // Auto map fetch state (see AUTOFETCH_* consts)
    var _autoFetchEnabled as Lang.Boolean;
    var _lastAutoFetchMs as Lang.Number;
    var _gpsTickCounter as Lang.Number;
    // Watch-side log: kept in a rolling in-memory buffer + persisted to
    // App.Storage (the "log file"). Nothing is transmitted continuously; the
    // whole buffer is streamed to the phone only when a get_logs request (or the
    // Settings "Send logs" item) sets _dumpPending. This avoids colliding with a
    // phone→watch sync (which caused FAILURE_DURING_TRANSFER) and survives crashes.
    var _logBuf as Lang.Array<Lang.String>;
    var _logTxBusy as Lang.Boolean;
    var _lastRxMs as Lang.Number;      // timer ms of last phone→watch message
    var _logDirty as Lang.Boolean;     // buffer changed since last persist
    var _dumpPending as Lang.Boolean;  // a log dump was requested
    var _dumpIdx as Lang.Number;       // next line index to stream during a dump
    var _persistTick as Lang.Number;   // throttles persistLog() from pollGps

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
        _autoFetchEnabled = readAutoFetchProperty();
        _lastAutoFetchMs = 0;
        _gpsTickCounter = 0;
        _logBuf = [] as Lang.Array<Lang.String>;
        _logTxBusy = false;
        _lastRxMs = 0;
        _bleStallDeadlineMs = 0;
        _logDirty = false;
        _dumpPending = false;
        _dumpIdx = 0;
        _persistTick = 0;
        loadPersistedLog();
    }

    // Append one line to the in-memory log buffer (cheap: add + cap at 300).
    function enqueueWatchLog(line as Lang.String) as Void {
        _logBuf.add(line);
        var n = _logBuf.size();
        if (n > 300) {
            _logBuf = _logBuf.slice(n - 300, n) as Lang.Array<Lang.String>;
        }
        _logDirty = true;
    }

    // Restore the log from Storage so pre-crash lines survive a restart.
    function loadPersistedLog() as Void {
        try {
            var v = App.Storage.getValue("watch_log_buf");
            if (v instanceof Lang.Array) {
                var buf = v as Lang.Array<Lang.String>;
                var n = buf.size();
                if (n > 300) { buf = buf.slice(n - 300, n) as Lang.Array<Lang.String>; }
                _logBuf = buf;
            }
        } catch (e) {
        }
    }

    // Persist the buffer to Storage ("log file"). One setValue every ~10 s from
    // pollGps (watchdog-safe) so a later crash still leaves the log on disk.
    function persistLog() as Void {
        if (!_logDirty) { return; }
        try {
            App.Storage.setValue("watch_log_buf", _logBuf);
            _logDirty = false;
        } catch (e) {
        }
    }

    // Request a full log dump to the phone (get_logs message / Settings item).
    function requestLogDump() as Void {
        _dumpPending = true;
        _dumpIdx = 0;
        appLog("log dump requested (" + _logBuf.size() + " lines)");
    }

    // Called ~1×/s from pollGps. Persists periodically; when a dump is pending,
    // streams the buffer to the phone one small batch at a time. Stays off the
    // air during active phone→watch traffic so it never breaks a sync.
    function serviceLog() as Void {
        _persistTick++;
        if (_persistTick >= 10) {
            _persistTick = 0;
            persistLog();
        }
        if (!_dumpPending || _logTxBusy) { return; }
        if (System.getTimer() - _lastRxMs < 3000) { return; }
        var total = _logBuf.size();
        if (_dumpIdx >= total) { _dumpPending = false; return; }
        var end = _dumpIdx + 8;
        if (end > total) { end = total; }
        var batch = _logBuf.slice(_dumpIdx, end) as Lang.Array<Lang.String>;
        var startIdx = _dumpIdx;
        _dumpIdx = end;
        _logTxBusy = true;
        try {
            Communications.transmit(
                { "kind" => "watch_log", "v" => 1, "from" => startIdx, "total" => total, "lines" => batch },
                null,
                new LogConnectionListener()
            );
        } catch (e) {
            _logTxBusy = false;
        }
    }

    function onLogTxDone() as Void {
        _logTxBusy = false;
    }

    function readAutoFetchProperty() as Lang.Boolean {
        try {
            var v = App.Properties.getValue("auto_fetch");
            if (v instanceof Lang.Boolean) { return v as Lang.Boolean; }
        } catch (e) {}
        return true;
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

    // Apply an explicit online-mode value (from the Settings menu).
    function setOnlineMode(v as Lang.Boolean) as Void {
        _onlineMode = v;
        try {
            App.Properties.setValue("online_mode", _onlineMode);
        } catch (e) {}
        System.println("[App] onlineMode=" + _onlineMode);
        if (_navView != null) {
            (_navView as NavigationView).setOnlineMode(_onlineMode);
        }
    }

    // Apply an explicit auto-fetch value (from the Settings menu).
    function setAutoFetch(v as Lang.Boolean) as Void {
        _autoFetchEnabled = v;
        try {
            App.Properties.setValue("auto_fetch", _autoFetchEnabled);
        } catch (e) {}
        System.println("[App] autoFetch=" + _autoFetchEnabled);
    }

    function onStart(state) {
        // Touch events are configured from NavigationView.onShow(): the
        // WatchUi.configureTouchEvents() API is only allowed while the app is
        // in the foreground, and onStart() runs before the initial view is
        // shown (calling it here throws an unhandled exception at startup).
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
        checkBleStall();
        serviceLog();
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
        maybeAutoFetch(lat, lon);
    }

    // Auto map fetch. Every check is O(1) float math; heavy work (quantize,
    // download) happens on the PHONE. The watch only sends one small transmit,
    // then rests for AUTOFETCH_COOLDOWN_MS — watchdog-safe by construction.
    function maybeAutoFetch(lat as Lang.Float, lon as Lang.Float) as Void {
        _gpsTickCounter++;
        if (_gpsTickCounter < AUTOFETCH_CHECK_EVERY) { return; }
        _gpsTickCounter = 0;
        if (!_autoFetchEnabled) { return; }
        var view = _navView;
        if (view == null) { return; }
        var v = view as NavigationView;
        if (v.getMapMode() != BG_MODE_TILES) { return; }
        var hdrN = v.getBundleHeader();
        if (hdrN == null) { return; }
        // Let the watch rest: never request while a transfer or decode is active.
        if (_dlBuffer != null || _pendingPersistBlob != null) { return; }
        if (_pendingTileChunkDicts.size() > 0) { return; }
        if (v.isDecodePending()) { return; }
        var now = System.getTimer();
        if (_lastAutoFetchMs != 0 && now - _lastAutoFetchMs < AUTOFETCH_COOLDOWN_MS) { return; }
        var hdr = hdrN as BundleHeader;
        var latSpan = hdr.maxLat - hdr.minLat;
        var lonSpan = hdr.maxLon - hdr.minLon;
        if (latSpan <= 0.0f || lonSpan <= 0.0f) { return; }
        var mLat = latSpan * AUTOFETCH_EDGE_FRACTION;
        var mLon = lonSpan * AUTOFETCH_EDGE_FRACTION;
        var nearEdge = lat > hdr.maxLat - mLat || lat < hdr.minLat + mLat
                    || lon > hdr.maxLon - mLon || lon < hdr.minLon + mLon;
        if (!nearEdge) { return; }
        _lastAutoFetchMs = now;
        appLog("auto map_request");
        try {
            Communications.transmit(
                {
                    "kind" => "map_request",
                    "lat" => lat,
                    "lon" => lon
                } as Lang.Dictionary,
                null,
                new NullConnectionListener()
            );
        } catch (e) {
            System.println("[AutoFetch] transmit failed: " + e.getErrorMessage());
        }
    }

    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        _lastRxMs = System.getTimer(); // pause watch-log tx around incoming traffic
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

        if ("get_logs".equals(kind)) {
            requestLogDump();
            return;
        }

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
        // A tile_session with a download_url is an explicit "fetch this bundle"
        // from the phone (it already uploaded it over HTTPS), so honor it even
        // when the watch is in offline mode. offline_mode only gates the
        // watch-initiated auto-fetch (map_request), not an offered bundle — the
        // download fails gracefully if GCM really has no connectivity.
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

    // Arm the stall watchdog: (re)set the 10 s deadline. Called on each accepted
    // chunk. No Timer object — checkBleStall() (from pollGps, 1 s) does the firing.
    function armBleStallTimer() as Void {
        _bleStallDeadlineMs = System.getTimer() + 10000;
    }

    // Transfer finished / cancelled — disable the stall check.
    function disarmBleStallTimer() as Void {
        _bleStallDeadlineMs = 0;
    }

    // Polled once per second from pollGps(). Resets a stalled assembler after the
    // deadline passes (10 s with no new chunk), then disables itself.
    function checkBleStall() as Void {
        if (_bleStallDeadlineMs == 0 || System.getTimer() < _bleStallDeadlineMs) {
            return;
        }
        _bleStallDeadlineMs = 0;
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

