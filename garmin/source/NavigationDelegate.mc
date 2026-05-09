using Toybox.Application as App;
using Toybox.Lang;
using Toybox.WatchUi;

class NavigationDelegate extends WatchUi.BehaviorDelegate {
    var _route as RouteData;
    var _view as NavigationView;

    function initialize(route as RouteData, view as NavigationView) {
        BehaviorDelegate.initialize();
        _route = route;
        _view = view;
    }

    // SELECT cycles map background mode (Native → Tiles → None → Native).
    function onSelect() as Lang.Boolean {
        _view.cycleMapMode();
        return true;
    }

    // UP toggles BLE online/offline mode.
    function onNextPage() as Lang.Boolean {
        (App.getApp() as GarmiandApp).toggleOnlineMode();
        return true;
    }

    function onBack() as Lang.Boolean {
        return false;
    }
}
