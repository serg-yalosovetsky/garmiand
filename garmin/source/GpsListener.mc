using Toybox.Position;
using Toybox.System;
using Toybox.WatchUi;

class GpsListener {
    var _onPosition;
    var _isActive;

    function initialize(onPosition) {
        _onPosition = onPosition;
        _isActive = false;
    }

    function start() {
        if (!_isActive) {
            System.println("[GPS] enableLocationEvents(CONTINUOUS)");
            Position.enableLocationEvents(
                Position.LOCATION_CONTINUOUS,
                method(:onPosition)
            );
            _isActive = true;
        }
    }

    function stop() {
        if (_isActive) {
            Position.enableLocationEvents(
                Position.LOCATION_DISABLE,
                method(:onPosition)
            );
            _isActive = false;
        }
    }

    function onPosition(info as Position.Info) as Void {
        System.println("[GPS] onPosition fired, accuracy=" + info.accuracy);
        if (info.accuracy == Position.QUALITY_NOT_AVAILABLE ||
            info.accuracy == Position.QUALITY_LAST_KNOWN) {
            System.println("[GPS] rejected (quality bad)");
            return;
        }
        var pos = info.position;
        if (pos == null) {
            System.println("[GPS] info.position is null");
            return;
        }
        var coords = pos.toDegrees();
        System.println("[GPS] coords lat=" + coords[0] + " lon=" + coords[1]);
        _onPosition.invoke(coords[0].toFloat(), coords[1].toFloat());
        WatchUi.requestUpdate();
    }
}
