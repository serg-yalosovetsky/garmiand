using Toybox.Application as App;
using Toybox.Communications;
using Toybox.WatchUi;

class GarmiandApp extends App.AppBase {
    var _syncStore;

    function initialize() {
        AppBase.initialize();
        _syncStore = {
            :chunks => [],
            :routeId => null
        };
    }

    function onStart(state) {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
    }

    function getInitialView() {
        return [ new NavigationView(_syncStore), new NavigationDelegate(_syncStore) ];
    }

    function onPhoneMessage(msg as Dictionary) as Void {
        if (msg == null || !msg.hasKey(:kind)) {
            return;
        }

        var kind = msg[:kind];

        if (kind == "sync_start") {
            _syncStore[:chunks] = [];
            _syncStore[:routeId] = msg[:routeId];
            return;
        }

        if (kind == "route_chunk") {
            _syncStore[:chunks].add(msg[:payload]);
            return;
        }

        if (kind == "sync_finish") {
            _syncStore[:ready] = true;
            WatchUi.requestUpdate();
        }
    }
}
