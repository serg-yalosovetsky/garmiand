using Toybox.Application as App;
using Toybox.Communications;
using Toybox.WatchUi;

class GarmiandApp extends App.AppBase {
    var _syncStore;

    function initialize() {
        AppBase.initialize();
        _syncStore = {
            :chunks => [],
            :routeId => null,
            :sessionId => null,
            :version => 1,
            :ready => false
        };
    }

    function onStart(state) {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
    }

    function getInitialView() {
        return [ new NavigationView(_syncStore), new NavigationDelegate(_syncStore) ];
    }

    function onPhoneMessage(msg as Dictionary) as Void {
        if (msg == null || !msg.hasKey("kind")) {
            return;
        }

        var kind = msg["kind"];

        if (kind == "sync_start") {
            _syncStore[:chunks] = [];
            _syncStore[:routeId] = msg["route_id"];
            _syncStore[:sessionId] = msg["session_id"];
            _syncStore[:version] = msg["v"];
            _syncStore[:ready] = false;
            WatchUi.requestUpdate();
            return;
        }

        if (kind == "route_chunk") {
            var entry = {
                :index => msg["chunk_index"],
                :count => msg["chunk_count"],
                :payload => msg["payload_b64"]
            };
            _syncStore[:chunks].add(entry);
            WatchUi.requestUpdate();
            return;
        }

        if (kind == "sync_finish") {
            _syncStore[:ready] = true;
            WatchUi.requestUpdate();
        }
    }
}
