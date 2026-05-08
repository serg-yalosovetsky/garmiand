# Map Rendering

How the map background and route overlay end up pixel-aligned on the watch.

## Pipeline (current)

1. **Phone picks a tile.** `TileComposer.singleTileForBbox(minLat, maxLat, minLon, maxLon)` walks zoom levels 18→0 and returns the first zoom at which the *padded* route bbox (15% padding around the route's own bbox) fits in a single 256×256 tile. Returns `(zoom, x, y, bbox)`.
2. **Phone sends `map_url`.** URL = `https://tile.openstreetmap.org/{z}/{x}/{y}.png`. Bbox = the tile's geographic bounds (not the route's bbox).
3. **Watch fetches the image.** `Communications.makeImageRequest(url, null, options, callback)` with `:maxWidth/:maxHeight = 240` (Fenix 7 screen). GCM downloads, optionally Floyd-Steinberg dithers, returns a `BitmapResource`.
4. **Watch projects the route.** `NavigationView.mapLonToX/mapLatToY` scale lon/lat from the *tile bbox* onto the bitmap rectangle (`mx`, `my`, `_mapWidth`, `_mapHeight`).

```
mapLonToX(lon) = mx + (lon - minLon) / (maxLon - minLon) * mapWidth
mapLatToY(lat) = my + (maxLat - lat) / (maxLat - minLat) * mapHeight
```

This is a linear approximation, valid because at one OSM tile the bbox is small enough that Web Mercator distortion within the tile is negligible at this resolution.

## Why a single tile, not a stitched composite

See ADR-003. GCM does not proxy HTTP requests to phone-local addresses (neither `127.0.0.1` nor LAN IP). It will proxy public HTTPS. A single OSM tile is the simplest public URL that gives a real map. `MapTileServer` exists in the codebase for the day a tunnel becomes available.

## Drawing order in `NavigationView.onUpdate`

When `_route.isComplete` and the bitmap exists:

```
1. fillBackground
2. drawBitmap (map)
3. drawPolylineMap (red)
4. drawMarkersMap (yellow circles, "Start"/"Finish" labels)
5. drawPositionMap (blue circle, OFF ROUTE banner)
6. drawTopBand + route name
7. drawBottomBanner (debug: map response code, last URL tail)
```

When map is missing, steps 2-5 are replaced by their scale-based equivalents (`drawPolyline`, `drawMarkers`, `drawPositionScale`) that use `_scale`, `_centerLat`, `_centerLon`. The fallback is a real fallback, not just a placeholder — auto-fit (`fitRoute`) computes a scale that makes the whole route fit on the 240×240 screen with 1.3× padding.

## Web Mercator math (in `TileComposer`)

```kotlin
latLonToTileFractional(lat, lon, zoom):
    n = 2^zoom
    x = (lon + 180) / 360 * n
    y = (1 - ln(tan(latRad) + 1/cos(latRad)) / π) / 2 * n

tileFractionalToLatLon(tx, ty, zoom):
    lon = tx / n * 360 - 180
    lat = atan(sinh(π * (1 - 2*ty/n))) → toDegrees
```

If you change projections, both the tile-pick and the watch-side `mapLonToX/mapLatToY` must change together.

## OSM Tile Usage Policy

`tile.openstreetmap.org` has a clearly stated [usage policy](https://operations.osmfoundation.org/policies/tiles/) — heavy use requires a self-hosted tile server. For an MVP at single-tile-per-route frequency this is fine; do not turn it into a per-frame fetcher.
