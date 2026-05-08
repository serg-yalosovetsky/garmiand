using Toybox.Position;
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

    function onPosition(info) {
        if (info == null) {
            return;
        }
        if (info.accuracy == Position.QUALITY_NOT_AVAILABLE ||
            info.accuracy == Position.QUALITY_LAST_KNOWN) {
            return;
        }
        var coords = info.position.toDegrees();
        _onPosition.invoke(coords[0].toFloat(), coords[1].toFloat());
        WatchUi.requestUpdate();
    }
}
