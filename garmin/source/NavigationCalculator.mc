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

    // Single-pass scan returning the minimum haversine distance to any route point.
    // Early-exits as soon as a point within the off-route threshold is found, so the
    // common case (user is on route) completes in O(1) instead of O(N).
    static function nearestDistance(route as RouteData, lat as Lang.Float, lon as Lang.Float) as Lang.Float {
        var bestDist = 999999.0f;
        var size = route.lats.size();
        for (var i = 0; i < size; i++) {
            var d = haversineM(lat, lon, route.lats[i], route.lons[i]);
            if (d < bestDist) {
                bestDist = d;
                if (bestDist < OFF_ROUTE_THRESHOLD_M) {
                    return bestDist;
                }
            }
        }
        return bestDist;
    }

    static function isOffRoute(route as RouteData, lat as Lang.Float, lon as Lang.Float) as Lang.Boolean {
        if (route.lats.size() == 0) { return false; }
        return nearestDistance(route, lat, lon) > OFF_ROUTE_THRESHOLD_M;
    }
}
