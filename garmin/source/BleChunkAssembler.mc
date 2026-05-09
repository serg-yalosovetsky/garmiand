using Toybox.Lang;
using Toybox.System;

// Reassembles a quantized map bundle from a stream of tile_chunk phone
// messages. The companion (MapBundleBleSender.kt) sends chunks in index
// order with ~150 ms gaps; we still index them by `i` so out-of-order
// arrivals don't corrupt the bundle.
class BleChunkAssembler {
    var _bundleId as Lang.String?;
    var _expectedTotal as Lang.Number;
    var _chunks as Lang.Dictionary<Lang.Number, Lang.ByteArray>;
    var _receivedCount as Lang.Number;
    var _knownChunkSize as Lang.Number;

    function initialize() {
        _bundleId = null;
        _expectedTotal = 0;
        _chunks = {};
        _receivedCount = 0;
        _knownChunkSize = 0;
    }

    function reset() as Void {
        _bundleId = null;
        _expectedTotal = 0;
        _chunks = {};
        _receivedCount = 0;
        _knownChunkSize = 0;
    }

    /**
     * Accept a tile_chunk dict. Returns the bundle id when the last chunk
     * lands and the blob has been persisted to Application.Storage. Returns
     * null while transfer is in progress or if a malformed message arrives.
     */
    function accept(dict as Lang.Dictionary) as Lang.String? {
        var incomingBundle = dict["bundle_id"] as Lang.String;
        var index = dict["i"];
        var total = dict["n"];
        var payload = dict["p"];

        if (incomingBundle == null || index == null || total == null || payload == null) {
            System.println("[Tiles] tile_chunk missing fields");
            return null;
        }
        if (!(payload instanceof Lang.ByteArray)) {
            System.println("[Tiles] tile_chunk payload not ByteArray: " + payload);
            return null;
        }
        var idx = (index as Lang.Numeric).toNumber();
        var tot = (total as Lang.Numeric).toNumber();
        var bytes = payload as Lang.ByteArray;

        if (_bundleId == null || !(_bundleId as Lang.String).equals(incomingBundle) || _expectedTotal != tot) {
            // New bundle (or restart) — drop any partial state.
            _bundleId = incomingBundle;
            _expectedTotal = tot;
            _chunks = {};
            _receivedCount = 0;
            _knownChunkSize = bytes.size();
            System.println("[Tiles] BLE bundle start " + incomingBundle + " total=" + tot);
        }

        if (!_chunks.hasKey(idx)) {
            _chunks.put(idx, bytes);
            _receivedCount++;
        }
        if (_receivedCount < _expectedTotal) {
            return null;
        }

        // All chunks received — assemble.
        var totalSize = 0;
        for (var i = 0; i < _expectedTotal; i++) {
            if (!_chunks.hasKey(i)) {
                System.println("[Tiles] missing chunk " + i + " — abort");
                reset();
                return null;
            }
            totalSize += (_chunks.get(i) as Lang.ByteArray).size();
        }

        var blob = new [totalSize]b;
        var off = 0;
        for (var j = 0; j < _expectedTotal; j++) {
            var ch = _chunks.get(j) as Lang.ByteArray;
            for (var k = 0; k < ch.size(); k++) {
                blob[off + k] = ch[k];
            }
            off += ch.size();
        }

        var assembledId = _bundleId as Lang.String;
        System.println("[Tiles] BLE bundle assembled " + assembledId + " size=" + totalSize);
        if (!TileDecoder.persist(assembledId, blob)) {
            reset();
            return null;
        }
        reset();
        return assembledId;
    }
}
