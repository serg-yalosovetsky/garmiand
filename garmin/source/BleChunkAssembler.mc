using Toybox.Lang;
using Toybox.System;

// Reassembles a quantized map bundle from a stream of tile_chunk phone
// messages. Uses a pre-allocated blob buffer (size = "tb" field) so each
// chunk is written directly in-place. Memory peak = totalBytes only,
// instead of totalBytes + N×chunkSize with the old dictionary approach.
class BleChunkAssembler {
    var _bundleId as Lang.String?;
    var _expectedTotal as Lang.Number;
    var _received as Lang.Dictionary<Lang.Number, Lang.Boolean>;
    var _receivedCount as Lang.Number;
    var _knownChunkSize as Lang.Number;
    var _blob as Lang.ByteArray?;
    var _totalBytes as Lang.Number;

    function initialize() {
        _bundleId = null;
        _expectedTotal = 0;
        _received = {};
        _receivedCount = 0;
        _knownChunkSize = 0;
        _blob = null;
        _totalBytes = 0;
    }

    function reset() as Void {
        _bundleId = null;
        _expectedTotal = 0;
        _received = {};
        _receivedCount = 0;
        _knownChunkSize = 0;
        _blob = null;
        _totalBytes = 0;
    }

    /**
     * Accept a tile_chunk dict. While in progress returns null. When the
     * last chunk lands returns a 2-element array [bundleId, blob]. Caller
     * is responsible for persisting and updating the view.
     */
    function accept(dict as Lang.Dictionary) as Lang.Array? {
        var incomingBundle = dict["bundle_id"] as Lang.String;
        var index = dict["i"];
        var total = dict["n"];
        var tbField = dict["tb"];
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
        var tb = (tbField instanceof Lang.Numeric) ? (tbField as Lang.Numeric).toNumber() : 0;
        var bytes = payload as Lang.ByteArray;

        if (_bundleId == null || !(_bundleId as Lang.String).equals(incomingBundle) || _expectedTotal != tot) {
            // New bundle (or restart) — allocate the final buffer up front.
            _bundleId = incomingBundle;
            _expectedTotal = tot;
            _received = {};
            _receivedCount = 0;
            _knownChunkSize = bytes.size();
            _totalBytes = tb;
            _blob = null;
            System.println("[Tiles] BLE bundle start " + incomingBundle + " total=" + tot + " bytes=" + tb);

            if (tb > 0) {
                try {
                    _blob = new [tb]b;
                } catch (e) {
                    System.println("[Tiles] pre-alloc " + tb + "B failed: " + e.getErrorMessage());
                    reset();
                    return [null, null, "alloc_fail:" + tb] as Lang.Array;
                }
            }
        }

        if (!_received.hasKey(idx)) {
            if (_blob != null) {
                var offset = idx * _knownChunkSize;
                var blob = _blob as Lang.ByteArray;
                for (var k = 0; k < bytes.size(); k++) {
                    blob[offset + k] = bytes[k];
                }
            }
            _received.put(idx, true);
            _receivedCount++;
        }

        if (_receivedCount < _expectedTotal) {
            return null;
        }

        // All chunks written into the pre-allocated buffer.
        if (_blob == null) {
            System.println("[Tiles] assembled but no blob — missing tb field?");
            reset();
            return [null, null, "no_blob"] as Lang.Array;
        }

        var assembledId = _bundleId as Lang.String;
        var blob = _blob as Lang.ByteArray;
        System.println("[Tiles] BLE bundle assembled " + assembledId + " size=" + blob.size());
        reset();
        return [assembledId, blob, null] as Lang.Array;
    }

    function progress() as Lang.Array<Lang.Number> {
        return [_receivedCount, _expectedTotal] as Lang.Array<Lang.Number>;
    }

    function getMissingIndices() as Lang.Array<Lang.Number> {
        var missing = [] as Lang.Array<Lang.Number>;
        for (var i = 0; i < _expectedTotal; i++) {
            if (!_received.hasKey(i)) {
                missing.add(i);
            }
        }
        return missing;
    }

    function getBundleId() as Lang.String? {
        return _bundleId;
    }
}
