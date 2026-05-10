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

    // SELECT: cycle interact sub-modes in TILES, cycle bg mode otherwise.
    function onSelect() as Lang.Boolean {
        _view.cycleMapMode();
        return true;
    }

    // UP: pan map north (NS mode) or west (WE mode) when in TILES.
    function onNextPage() as Lang.Boolean {
        if (_view.getMapMode() == BG_MODE_TILES) {
            _view.interactUp();
        } else {
            (App.getApp() as GarmiandApp).toggleOnlineMode();
        }
        return true;
    }

    // DOWN: pan map south (NS mode) or east (WE mode) when in TILES.
    function onPreviousPage() as Lang.Boolean {
        if (_view.getMapMode() == BG_MODE_TILES) {
            _view.interactDown();
        }
        return true;
    }

    // BACK: center to GPS position in TILES mode; exit app otherwise.
    function onBack() as Lang.Boolean {
        if (_view.getMapMode() == BG_MODE_TILES) {
            _view.centerToGps();
            return true;
        }
        return false;
    }
}
