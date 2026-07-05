using Toybox.Application as App;
using Toybox.Lang;
using Toybox.WatchUi;

// On-watch settings, opened by holding the START button. Minimal set of the
// properties the app actually reads at runtime. Toggling an item applies it
// immediately (persisted to App.Properties and pushed into the running app).
class SettingsMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({:title => "Settings"});
        addItem(new WatchUi.ToggleMenuItem(
            "Online maps", null, :online_mode, readBool("online_mode", true), null));
        addItem(new WatchUi.ToggleMenuItem(
            "Auto fetch", null, :auto_fetch, readBool("auto_fetch", true), null));
        addItem(new WatchUi.MenuItem(
            "Send logs", "→ phone → Loki", :send_logs, null));
    }

    function readBool(key as Lang.String, dflt as Lang.Boolean) as Lang.Boolean {
        try {
            var v = App.Properties.getValue(key);
            if (v instanceof Lang.Boolean) { return v as Lang.Boolean; }
        } catch (e) {
        }
        return dflt;
    }
}

class SettingsMenuDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        var app = App.getApp();
        if (!(app instanceof GarmiandApp)) { return; }
        if (id == :send_logs) {
            (app as GarmiandApp).requestLogDump();
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            return;
        }
        // Toggle items only past this point.
        var on = (item as WatchUi.ToggleMenuItem).isEnabled();
        if (id == :online_mode) {
            (app as GarmiandApp).setOnlineMode(on);
        } else if (id == :auto_fetch) {
            (app as GarmiandApp).setAutoFetch(on);
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
