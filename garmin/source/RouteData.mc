using Toybox.Lang;

class RouteData {
    var routeId as Lang.String?;
    var routeName as Lang.String?;
    var lats as Lang.Array<Lang.Float>;
    var lons as Lang.Array<Lang.Float>;
    var markerIds as Lang.Array<Lang.String>;
    var markerLats as Lang.Array<Lang.Float>;
    var markerLons as Lang.Array<Lang.Float>;
    var markerTitles as Lang.Array<Lang.String>;
    var expectedChunkCount as Lang.Number;
    var receivedChunkCount as Lang.Number;
    var isComplete as Lang.Boolean;

    function initialize() {
        routeId = null;
        routeName = null;
        lats = [] as Lang.Array<Lang.Float>;
        lons = [] as Lang.Array<Lang.Float>;
        markerIds = [] as Lang.Array<Lang.String>;
        markerLats = [] as Lang.Array<Lang.Float>;
        markerLons = [] as Lang.Array<Lang.Float>;
        markerTitles = [] as Lang.Array<Lang.String>;
        expectedChunkCount = 0;
        receivedChunkCount = 0;
        isComplete = false;
    }

    function reset() as Void {
        initialize();
    }

    function addChunk(chunkLats as Lang.Array, chunkLons as Lang.Array) as Void {
        for (var i = 0; i < chunkLats.size(); i++) {
            lats.add((chunkLats[i] as Lang.Numeric).toFloat());
            lons.add((chunkLons[i] as Lang.Numeric).toFloat());
        }
        receivedChunkCount++;
    }

    function setMarkers(rawMarkers as Lang.Array) as Void {
        markerIds = [] as Lang.Array<Lang.String>;
        markerLats = [] as Lang.Array<Lang.Float>;
        markerLons = [] as Lang.Array<Lang.Float>;
        markerTitles = [] as Lang.Array<Lang.String>;
        for (var i = 0; i < rawMarkers.size(); i++) {
            var m = rawMarkers[i] as Lang.Dictionary;
            markerIds.add(m["id"] as Lang.String);
            markerLats.add((m["lat"] as Lang.Numeric).toFloat());
            markerLons.add((m["lon"] as Lang.Numeric).toFloat());
            markerTitles.add(m["title"] as Lang.String);
        }
    }

    function pointCount() as Lang.Number {
        return lats.size();
    }
}
