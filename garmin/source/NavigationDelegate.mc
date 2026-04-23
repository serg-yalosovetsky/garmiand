using Toybox.WatchUi;

class NavigationDelegate extends WatchUi.BehaviorDelegate {
    var _store;

    function initialize(store) {
        BehaviorDelegate.initialize();
        _store = store;
    }
}
