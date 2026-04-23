using Toybox.Graphics;
using Toybox.WatchUi;

class NavigationView extends WatchUi.View {
    var _store;

    function initialize(store) {
        View.initialize();
        _store = store;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var title = "Garmiand V1";
        var status = _store[:ready] ? "Route synced" : "Waiting sync";
        var chunks = _store[:chunks] != null ? _store[:chunks].size() : 0;
        var version = _store[:version] != null ? _store[:version] : 0;

        dc.drawText(dc.getWidth()/2, 44, Graphics.FONT_MEDIUM, title, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(dc.getWidth()/2, 78, Graphics.FONT_SMALL, status, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(dc.getWidth()/2, 106, Graphics.FONT_TINY, "v=" + version + " chunks=" + chunks, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
