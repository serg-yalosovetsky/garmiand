using Toybox.Application as App;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Hold this long on the START (mode) button to open Settings.
const ENTER_LONG_MS = 600;
// Two START presses within this window count as a double-press (jump to GPS).
const ENTER_DOUBLE_MS = 280;

// Control scheme (fenix 5-button):
//   START single  -> cycle the 3 interaction modes (scroll NS / scroll WE / zoom)
//   START double  -> jump to current GPS position on the map
//   START hold    -> open Settings
//   UP / DOWN     -> act per the active interaction mode
//   BACK          -> exit the app (default behavior, not intercepted)
//
// The START button is handled through raw onKey() so we can tell single,
// double and long presses apart. Every other key is forwarded to the
// BehaviorDelegate so UP/DOWN/BACK keep their normal callbacks.
class NavigationDelegate extends WatchUi.BehaviorDelegate {
    var _route as RouteData;
    var _view as NavigationView;
    var _dragPrevX as Lang.Number;
    var _dragPrevY as Lang.Number;

    // START-button press disambiguation state.
    var _enterDown as Lang.Boolean;
    var _longFired as Lang.Boolean;
    var _pendingSingle as Lang.Boolean;
    var _longTimer as Timer.Timer?;
    var _singleTimer as Timer.Timer?;

    function initialize(route as RouteData, view as NavigationView) {
        BehaviorDelegate.initialize();
        _route = route;
        _view = view;
        _dragPrevX = 0;
        _dragPrevY = 0;
        _enterDown = false;
        _longFired = false;
        _pendingSingle = false;
        _longTimer = null;
        _singleTimer = null;
    }

    // START pressed down: start timing a possible long press. Every other key
    // is left to the default behavior mapping (onNextPage/onPreviousPage/exit).
    function onKeyPressed(evt as WatchUi.KeyEvent) as Lang.Boolean {
        if (evt.getKey() == WatchUi.KEY_ENTER) {
            _enterDown = true;
            _longFired = false;
            armLongTimer();
            return true;
        }
        return false;
    }

    // START released: a long press already fired -> swallow it; otherwise this
    // is a click, fed into the single/double disambiguation.
    function onKeyReleased(evt as WatchUi.KeyEvent) as Lang.Boolean {
        if (evt.getKey() == WatchUi.KEY_ENTER) {
            _enterDown = false;
            disarmLongTimer();
            if (_longFired) {
                _longFired = false;
            } else {
                handleEnterClick();
            }
            return true;
        }
        return false;
    }

    // ---- START press timing helpers -------------------------------------

    function armLongTimer() as Void {
        disarmLongTimer();
        var t = new Timer.Timer();
        t.start(method(:onLongExpire), ENTER_LONG_MS, false);
        _longTimer = t;
    }

    function disarmLongTimer() as Void {
        if (_longTimer != null) {
            (_longTimer as Timer.Timer).stop();
            _longTimer = null;
        }
    }

    // Fires while START is still held -> treat as a long press (Settings).
    function onLongExpire() as Void {
        _longTimer = null;
        if (_enterDown) {
            _longFired = true;
            cancelPendingSingle();
            openSettings();
        }
    }

    // A completed START click: first click waits for a possible second one.
    function handleEnterClick() as Void {
        if (_pendingSingle) {
            cancelPendingSingle();
            _view.centerToGps();           // double press -> jump to GPS
        } else {
            _pendingSingle = true;
            var t = new Timer.Timer();
            t.start(method(:onSingleExpire), ENTER_DOUBLE_MS, false);
            _singleTimer = t;
        }
    }

    // No second click arrived in time -> it was a single press.
    function onSingleExpire() as Void {
        _singleTimer = null;
        if (_pendingSingle) {
            _pendingSingle = false;
            _view.cycleMapMode();          // single press -> cycle 3 modes
        }
    }

    function cancelPendingSingle() as Void {
        if (_singleTimer != null) {
            (_singleTimer as Timer.Timer).stop();
            _singleTimer = null;
        }
        _pendingSingle = false;
    }

    function openSettings() as Void {
        WatchUi.pushView(new SettingsMenu(), new SettingsMenuDelegate(), WatchUi.SLIDE_UP);
    }

    // ---- Other inputs ----------------------------------------------------

    // UP button: act per the active interaction mode.
    function onNextPage() as Lang.Boolean {
        _view.interactUp();
        return true;
    }

    // DOWN button: act per the active interaction mode.
    function onPreviousPage() as Lang.Boolean {
        _view.interactDown();
        return true;
    }

    // Drag handler: pans the map in real time as the finger moves.
    function onDrag(evt as WatchUi.DragEvent) as Lang.Boolean {
        var type = evt.getType();
        var coords = evt.getCoordinates();
        if (coords == null) { return false; }
        var x = (coords[0] as Lang.Numeric).toNumber();
        var y = (coords[1] as Lang.Numeric).toNumber();

        if (type == WatchUi.DRAG_TYPE_START) {
            _dragPrevX = x;
            _dragPrevY = y;
            return true;
        }
        if (type == WatchUi.DRAG_TYPE_CONTINUE || type == WatchUi.DRAG_TYPE_STOP) {
            var dx = x - _dragPrevX;
            var dy = y - _dragPrevY;
            _dragPrevX = x;
            _dragPrevY = y;
            if (dx != 0 || dy != 0) {
                _view.panByPixels(dx, dy);
            }
            return true;
        }
        return false;
    }
}
