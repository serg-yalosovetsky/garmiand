using Toybox.Application as App;
using Toybox.Lang;
using Toybox.System;
using Toybox.WatchUi;

class NavigationDelegate extends WatchUi.BehaviorDelegate {
    var _route as RouteData;
    var _view as NavigationView;
    var _lastBackMs as Lang.Number;

    function initialize(route as RouteData, view as NavigationView) {
        BehaviorDelegate.initialize();
        _route = route;
        _view = view;
        _lastBackMs = 0;
    }

    // SELECT: cycle interact sub-modes in TILES, cycle bg mode otherwise.
    function onSelect() as Lang.Boolean {
        _view.cycleMapMode();
        return true;
    }

    // UP: zoom/pan in TILES; toggle online mode otherwise.
    function onNextPage() as Lang.Boolean {
        if (_view.getMapMode() == BG_MODE_TILES) {
            _view.interactUp();
        } else {
            (App.getApp() as GarmiandApp).toggleOnlineMode();
        }
        return true;
    }

    // DOWN: zoom/pan in TILES.
    function onPreviousPage() as Lang.Boolean {
        if (_view.getMapMode() == BG_MODE_TILES) {
            _view.interactDown();
        }
        return true;
    }

    // BACK single: center viewport on GPS position (falls back to route center if no fix).
    // BACK double (< 500 ms): exit app unconditionally.
    function onBack() as Lang.Boolean {
        var now = System.getTimer();
        if (_lastBackMs > 0 && now - _lastBackMs < 500) {
            _lastBackMs = 0;
            return false;  // pass to system → exits app
        }
        _lastBackMs = now;
        _view.centerToGps();
        return true;
    }
}
