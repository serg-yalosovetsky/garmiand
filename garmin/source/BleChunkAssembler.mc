using Toybox.Application as App;
using Toybox.Lang;
using Toybox.System;

// Reassembles a quantized map bundle from a stream of tile_chunk phone
// messages. Uses a pre-allocated blob buffer (size = "tb" field) so each
// chunk is written directly in-place. Memory peak = totalBytes only,
// instead of totalBytes + N×chunkSize with the old dictionary approach.
//
// WIP persistence: after each chunk is written, persistChunkWip() stores the
// raw payload in App.Storage ("ble_wip_c_N"). On app restart, loadWip()
// rebuilds the assembler from storage so transfer can resume from where it
// left off. clearWip() removes all WIP keys when the bundle is fully assembled.
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
     * last chunk lands returns a 2-element array [bundleId, blob, null] or
     * [null, null, errorString] on error. Persists each new chunk to Storage
     * for resumable transfer across app restarts.
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
        var idx = (index as Lang.Number).toNumber();
        var tot = (total as Lang.Number).toNumber();
        var tb = (tbField instanceof Lang.Number) ? (tbField as Lang.Number).toNumber() : 0;
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
            // Persist this chunk so the transfer can be resumed after app restart.
            persistChunkWip(idx, bytes);
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

    function getReceivedIndices() as Lang.Array<Lang.Number> {
        var indices = [] as Lang.Array<Lang.Number>;
        var keys = _received.keys();
        for (var i = 0; i < keys.size(); i++) {
            indices.add(keys[i] as Lang.Number);
        }
        return indices;
    }

    function getBundleId() as Lang.String? {
        return _bundleId;
    }

    // Persist one chunk payload to Storage and update WIP metadata.
    // Called after each new (non-duplicate) chunk is written to _blob.
    function persistChunkWip(idx as Lang.Number, bytes as Lang.ByteArray) as Void {
        try {
            App.Storage.setValue("ble_wip_c_" + idx, bytes);
            App.Storage.setValue("ble_wip_id", _bundleId);
            App.Storage.setValue("ble_wip_tot", _expectedTotal);
            App.Storage.setValue("ble_wip_sz", _totalBytes);
            App.Storage.setValue("ble_wip_csz", _knownChunkSize);
            App.Storage.setValue("ble_wip_n", _receivedCount);
        } catch (e) {
            System.println("[BLE] persistChunkWip " + idx + " failed: " + e.getErrorMessage());
        }
    }

    // Restore a partially-assembled bundle from Storage. Returns null if no
    // valid WIP exists or the transfer was already complete.
    static function loadWip() as BleChunkAssembler? {
        try {
            var id = App.Storage.getValue("ble_wip_id");
            var tot = App.Storage.getValue("ble_wip_tot");
            var sz = App.Storage.getValue("ble_wip_sz");
            var csz = App.Storage.getValue("ble_wip_csz");
            var n = App.Storage.getValue("ble_wip_n");
            if (!(id instanceof Lang.String) || !(tot instanceof Lang.Number) ||
                !(sz instanceof Lang.Number) || !(csz instanceof Lang.Number) ||
                !(n instanceof Lang.Number)) {
                return null;
            }
            var totN = (tot as Lang.Number).toNumber();
            var szN = (sz as Lang.Number).toNumber();
            var cszN = (csz as Lang.Number).toNumber();
            var nN = (n as Lang.Number).toNumber();
            if (nN <= 0 || nN >= totN || szN <= 0 || cszN <= 0) {
                return null;
            }
            var blob = new [szN]b;
            var received = {} as Lang.Dictionary<Lang.Number, Lang.Boolean>;
            var rcvCount = 0;
            for (var i = 0; i < totN; i++) {
                var chunkData = App.Storage.getValue("ble_wip_c_" + i);
                if (!(chunkData instanceof Lang.ByteArray)) {
                    continue;
                }
                var ch = chunkData as Lang.ByteArray;
                var offset = i * cszN;
                var chSize = ch.size();
                for (var k = 0; k < chSize; k++) {
                    blob[offset + k] = ch[k];
                }
                received.put(i, true);
                rcvCount++;
            }
            if (rcvCount == 0) {
                return null;
            }
            var asm = new BleChunkAssembler();
            asm._bundleId = id as Lang.String;
            asm._expectedTotal = totN;
            asm._totalBytes = szN;
            asm._knownChunkSize = cszN;
            asm._blob = blob;
            asm._received = received;
            asm._receivedCount = rcvCount;
            System.println("[BLE] WIP restored " + rcvCount + "/" + totN + " for " + (id as Lang.String).substring(0, 8));
            return asm;
        } catch (e) {
            System.println("[BLE] loadWip failed: " + e.getErrorMessage());
            return null;
        }
    }

    // Delete all WIP Storage keys. Called when the bundle is fully assembled
    // and queued for normal persist (TileDecoder.persist).
    static function clearWip() as Void {
        try {
            var tot = App.Storage.getValue("ble_wip_tot");
            if (tot instanceof Lang.Number) {
                var n = (tot as Lang.Number).toNumber();
                for (var i = 0; i < n; i++) {
                    App.Storage.deleteValue("ble_wip_c_" + i);
                }
            }
            App.Storage.deleteValue("ble_wip_id");
            App.Storage.deleteValue("ble_wip_tot");
            App.Storage.deleteValue("ble_wip_sz");
            App.Storage.deleteValue("ble_wip_csz");
            App.Storage.deleteValue("ble_wip_n");
            System.println("[BLE] WIP cleared");
        } catch (e) {
            System.println("[BLE] clearWip failed: " + e.getErrorMessage());
        }
    }
}
