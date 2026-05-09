using Toybox.WatchUi;

class NavigationDelegate extends WatchUi.BehaviorDelegate {
    var _route as RouteData;
    var _view as NavigationView;

    function initialize(route as RouteData, view as NavigationView) {
        BehaviorDelegate.initialize();
        _route = route;
        _view = view;
    }

    // SELECT — cycle map mode (Native → Tiles → None → Native).
    // UP/DOWN are consumed by MapView.MAP_MODE_BROWSE for native pan/zoom.
    function onSelect() as Lang.Boolean {
        _view.cycleMapMode();
        return true;
    }

    function onBack() as Lang.Boolean {
        return false;
    }
}
