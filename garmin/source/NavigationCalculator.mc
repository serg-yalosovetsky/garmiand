using Toybox.Lang;
using Toybox.Math;

const OFF_ROUTE_THRESHOLD_M = 40.0;
const EARTH_RADIUS_M = 6371000.0;

class NavigationCalculator {

    static function haversineM(lat1 as Lang.Float, lon1 as Lang.Float, lat2 as Lang.Float, lon2 as Lang.Float) as Lang.Float {
        var dLat = Math.toRadians(lat2 - lat1);
        var dLon = Math.toRadians(lon2 - lon1);
        var sinDLat = Math.sin(dLat / 2.0);
        var sinDLon = Math.sin(dLon / 2.0);
        var a = sinDLat * sinDLat
              + Math.cos(Math.toRadians(lat1))
              * Math.cos(Math.toRadians(lat2))
              * sinDLon * sinDLon;
        return (2.0 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a))).toFloat();
    }

    static function nearestPointIndex(route as RouteData, lat as Lang.Float, lon as Lang.Float) as Lang.Number {
        var bestIdx = 0;
        var bestDist = 999999.0;
        var size = route.lats.size();
        for (var i = 0; i < size; i++) {
            var d = haversineM(lat, lon, route.lats[i], route.lons[i]);
            if (d < bestDist) {
                bestDist = d;
                bestIdx = i;
            }
        }
        return bestIdx;
    }

    static function distanceToRoute(route as RouteData, lat as Lang.Float, lon as Lang.Float) as Lang.Float {
        if (route.lats.size() == 0) {
            return 0.0;
        }
        var idx = nearestPointIndex(route, lat, lon);
        return haversineM(lat, lon, route.lats[idx], route.lons[idx]);
    }

    static function isOffRoute(route as RouteData, lat as Lang.Float, lon as Lang.Float) as Lang.Boolean {
        return distanceToRoute(route, lat, lon) > OFF_ROUTE_THRESHOLD_M;
    }
}
