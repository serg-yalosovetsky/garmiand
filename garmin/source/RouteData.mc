using Toybox.Lang;

class RouteData {
    var routeId;
    var routeName;
    var lats;
    var lons;
    var markerIds;
    var markerLats;
    var markerLons;
    var markerTitles;
    var expectedChunkCount;
    var receivedChunkCount;
    var isComplete;

    function initialize() {
        routeId = null;
        routeName = null;
        lats = [];
        lons = [];
        markerIds = [];
        markerLats = [];
        markerLons = [];
        markerTitles = [];
        expectedChunkCount = 0;
        receivedChunkCount = 0;
        isComplete = false;
    }

    function reset() {
        initialize();
    }

    function addChunk(chunkLats, chunkLons) {
        for (var i = 0; i < chunkLats.size(); i++) {
            lats.add(chunkLats[i].toFloat());
            lons.add(chunkLons[i].toFloat());
        }
        receivedChunkCount++;
    }

    function setMarkers(rawMarkers) {
        markerIds = [];
        markerLats = [];
        markerLons = [];
        markerTitles = [];
        for (var i = 0; i < rawMarkers.size(); i++) {
            var m = rawMarkers[i];
            markerIds.add(m["id"]);
            markerLats.add(m["lat"].toFloat());
            markerLons.add(m["lon"].toFloat());
            markerTitles.add(m["title"]);
        }
    }

    function pointCount() {
        return lats.size();
    }
}
