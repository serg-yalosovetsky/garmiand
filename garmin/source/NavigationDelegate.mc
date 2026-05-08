using Toybox.WatchUi;

class NavigationDelegate extends WatchUi.BehaviorDelegate {
    var _route;
    var _view;

    function initialize(route, view) {
        BehaviorDelegate.initialize();
        _route = route;
        _view = view;
    }

    // UP — zoom in
    function onPreviousPage() {
        _view.zoomIn();
        WatchUi.requestUpdate();
        return true;
    }

    // DOWN — zoom out
    function onNextPage() {
        _view.zoomOut();
        WatchUi.requestUpdate();
        return true;
    }

    // SELECT — toggle auto-center
    function onSelect() {
        _view.toggleAutoCenter();
        WatchUi.requestUpdate();
        return true;
    }

    // BACK — выйти из приложения
    function onBack() {
        return false;
    }
}
