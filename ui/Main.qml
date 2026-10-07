// Dufs - a Basecamp view over dufs file servers (https://github.com/sigoden/dufs).
//
// Pure QML: the Basecamp 0.3 sandbox gives a view no network and no files outside its own
// install dir, so every request runs in the dufs_core module. This view renders
// dufs_core.snapshot(), polled (fast while something is loading or transferring), and hands
// image previews to the core, which caches them under <this dir>/cache where Image can load them.
//
// Every core call goes through callVia (logos.callModuleAsync; never a blocking call in a view).
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

import Logos.Theme
import Logos.Controls

Item {
    id: root
    width: 1100
    height: 720

    // ── colours: design-system tokens with fallbacks (a missing token is undefined, not fatal)
    function tok(v, fb) { return (v === undefined || v === null) ? fb : v }
    readonly property var pal: (typeof Theme !== "undefined" && Theme.palette) ? Theme.palette : ({})
    readonly property color cBg: tok(pal.background, "#141416")
    readonly property color cSurface: tok(pal.surface, "#1c1c20")
    readonly property color cRaised: tok(pal.surfaceRaised, "#26262c")
    readonly property color cText: tok(pal.text, "#ececf1")
    readonly property color cSub: tok(pal.textSecondary, "#a8a8b3")
    readonly property color cFaint: tok(pal.textTertiary, "#74747f")
    readonly property color cLine: tok(pal.borderHairline, "#2e2e36")
    readonly property color cAccent: tok(pal.primary, "#ff7a3d")
    readonly property color cOk: tok(pal.success, "#5fbf7f")
    readonly property color cBad: tok(pal.error, "#ef6f6c")
    readonly property int sp: 8

    // ── core bridge
    readonly property string coreName: "dufs_core"
    readonly property int callTimeoutMs: 30000
    function _deliver(cb, raw) {
        if (!cb) return
        try { cb(raw === undefined || raw === null ? "" : raw) } catch (e) { console.warn("dufs view: callback error: " + e) }
    }
    function callVia(module, method, args, cb) {
        var a = args || []
        if (typeof logos === "undefined" || logos === null) { Qt.callLater(function () { root._deliver(cb, "") }); return }
        if (typeof logos.callModuleAsync === "function") {
            try { logos.callModuleAsync(module, method, a, function (res) { root._deliver(cb, res) }, root.callTimeoutMs) }
            catch (e) { Qt.callLater(function () { root._deliver(cb, "") }) }
            return
        }
        Qt.callLater(function () {
            var raw = ""
            try { raw = (typeof logos.callModule === "function") ? logos.callModule(module, method, a) : "" } catch (e) { raw = "" }
            root._deliver(cb, raw)
        })
    }
    // Results may arrive as JSON, or JSON-quoted once or twice.
    function parse(raw) {
        var v = raw
        for (var i = 0; i < 3 && typeof v === "string"; i++) {
            var s = v.trim()
            if (s === "") return null
            try { v = JSON.parse(s) } catch (e) { return null }
        }
        return (v && typeof v === "object") ? v : null
    }

    // ── state
    property var st: ({ servers: [], entries: [], transfers: [], previews: {}, perms: {}, path: "/", current: "" })
    property bool coreSeen: false
    property int missedPolls: 0
    property bool busy: false
    property bool again: false
    property double lastNoticeAt: 0
    property string selectedPath: ""
    property string sortBy: "name"
    property bool sortDesc: false
    property bool gridMode: false
    property var requested: ({})
    property bool dropHover: false
    // The core answered before and has now gone quiet: it stopped or crashed.
    readonly property bool coreLost: root.coreSeen && root.missedPolls >= 4

    readonly property var servers: st.servers || []
    readonly property var currentServer: {
        for (var i = 0; i < servers.length; i++) if (servers[i].id === st.current) return servers[i]
        return null
    }
    readonly property bool anyActive: !!st.loading || activeTransfers > 0 || pendingPreviews > 0
    readonly property int activeTransfers: {
        var n = 0, t = st.transfers || []
        for (var i = 0; i < t.length; i++) if (t[i].state === "running" || t[i].state === "queued") n++
        return n
    }
    readonly property int pendingPreviews: {
        var n = 0, p = st.previews || {}
        for (var k in p) if (p[k].state === "loading") n++
        return n
    }
    readonly property var sortedEntries: {
        var e = (st.entries || []).slice()
        var key = root.sortBy, desc = root.sortDesc
        e.sort(function (a, b) {
            if (a.dir !== b.dir) return a.dir ? -1 : 1
            var r = 0
            if (key === "size") r = (a.size || 0) - (b.size || 0)
            else if (key === "date") r = (a.mtime || 0) - (b.mtime || 0)
            else r = a.name.toLowerCase() < b.name.toLowerCase() ? -1 : (a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0)
            return desc ? -r : r
        })
        return e
    }
    readonly property var selectedEntry: {
        var e = st.entries || []
        for (var i = 0; i < e.length; i++) if (e[i].path === root.selectedPath) return e[i]
        return null
    }
    readonly property var selectedPreview: selectedEntry ? ((st.previews || {})[selectedEntry.path] || null) : null

    function apply(obj) {
        if (!obj) return
        if (obj.ok === false) { toast(obj.error || "That did not work.", true); return }
        if (obj.servers === undefined) return
        root.st = obj
        root.coreSeen = true
        root.missedPolls = 0
        if (obj.notice && obj.noticeAt && obj.noticeAt > root.lastNoticeAt) {
            if (root.lastNoticeAt > 0) toast(obj.notice, obj.noticeKind === "error")
            root.lastNoticeAt = obj.noticeAt
        } else if (root.lastNoticeAt === 0) root.lastNoticeAt = obj.noticeAt || 1
        if (!obj.previewCache) registerViewDir()
    }
    function refresh() {
        if (root.busy) { root.again = true; return }
        root.busy = true
        callVia(coreName, "snapshot", [], function (raw) {
            var o = parse(raw)
            if (o) apply(o)
            else root.missedPolls++
            root.busy = false
            if (root.again) { root.again = false; root.refresh() }
        })
    }
    // Every action: the core answers with the fresh state, or {ok:false,error}.
    function act(method, args, okMsg) {
        callVia(coreName, method, args, function (raw) {
            var o = parse(raw)
            if (!o) { toast("No answer from dufs_core - is it installed and loaded?", true); return }
            if (o.ok === false) { toast(o.error || "That did not work.", true); return }
            apply(o)
            if (okMsg) toast(okMsg, false)
        })
    }
    function viewDir() {
        var u = String(Qt.resolvedUrl("."))
        if (u.indexOf("file://") === 0) u = decodeURIComponent(u.substring(7))
        return u
    }
    property bool viewDirSent: false
    function registerViewDir() {
        if (root.viewDirSent && root.st.previewCache) return
        root.viewDirSent = true
        callVia(coreName, "setViewDir", [viewDir()], function (raw) { var o = parse(raw); if (o) apply(o) })
    }

    function openDir(p) { root.selectedPath = ""; root.requested = ({}); act("openDir", [p]) }
    function goUp() {
        var p = st.path || "/"
        if (p === "/") return
        var s = p.substring(0, p.length - 1)
        openDir(s.substring(0, s.lastIndexOf("/") + 1))
    }
    function activate(e) {
        if (e.dir) { openDir(e.path); return }
        root.selectedPath = e.path
        wantPreview(e)
    }
    function wantPreview(e) {
        if (!e || e.dir) return
        if (e.kind !== "image" && e.kind !== "text") return
        if (root.requested[e.path]) return
        var r = root.requested; r[e.path] = true; root.requested = r
        act("preview", [e.path])
    }
    // The file:// URL of a local path; each segment encoded so names with #, ? or % survive.
    function fileUrl(path) {
        return "file://" + String(path).split("/").map(function (seg) { return encodeURIComponent(seg) }).join("/")
    }
    function askSave(e) {
        if (!e) return
        var dir = root.st.downloadsDir || ""
        var name = e.name + (e.dir ? ".zip" : "")
        saveDialog.target = e
        if (dir) saveDialog.currentFolder = root.fileUrl(dir)
        saveDialog.selectedFile = root.fileUrl((dir ? dir : "") + "/" + name)
        saveDialog.open()
    }
    // A file-picker or drop URL -> its file name.
    function baseOf(u) {
        var s = String(u)
        try { s = decodeURIComponent(s) } catch (e) {}
        return s.substring(s.lastIndexOf("/") + 1)
    }
    // Uploading over an existing name replaces it on the server: ask first.
    function uploadUrls(urls) {
        var list = []
        for (var i = 0; i < urls.length; i++) list.push(String(urls[i]))
        if (!list.length) return
        var existing = {}
        var es = root.st.entries || []
        for (var k = 0; k < es.length; k++) if (!es[k].dir) existing[es[k].name] = true
        var clashes = list.filter(function (u) { return existing[root.baseOf(u)] })
        if (clashes.length && !root.st.query) { replaceDialog.ask(list, clashes); return }
        root.uploadNow(list)
    }
    function uploadNow(urls) {
        var list = []
        for (var i = 0; i < urls.length; i++) list.push(String(urls[i]))
        if (!list.length) return
        if (!currentServer) { toast("Add a server first.", true); return }
        if (st.perms && st.perms.upload === false) { toast("This server does not allow uploads (start dufs with --allow-upload or -A).", true); return }
        act("upload", [JSON.stringify(list)], list.length === 1 ? "Uploading 1 file" : "Uploading " + list.length + " files")
    }

    // ── formatting
    function fmtSize(n, dir) {
        // dufs caps a folder's count at 1000
        if (dir) return n === 1 ? "1 item" : (n >= 1000 ? "1000+ items" : (n || 0) + " items")
        if (n === undefined || n === null) return ""
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0, v = n
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++ }
        return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)) + " " + u[i]
    }
    function fmtDate(ms) {
        if (!ms) return ""
        var d = new Date(ms), now = new Date()
        if (d.toDateString() === now.toDateString()) return "Today " + Qt.formatTime(d, "hh:mm")
        return Qt.formatDate(d, d.getFullYear() === now.getFullYear() ? "d MMM" : "d MMM yyyy") + " " + Qt.formatTime(d, "hh:mm")
    }
    function glyph(kind) {
        switch (kind) {
        case "dir": return "▤"
        case "image": return "▣"
        case "text": return "≣"
        case "video": return "▶"
        case "audio": return "♪"
        case "archive": return "▧"
        case "document": return "▤"
        default: return "□"
        }
    }
    function kindColor(kind) {
        switch (kind) {
        case "dir": return root.cAccent
        case "image": return "#6fb6ff"
        case "text": return "#b5a2ff"
        case "video": return "#ff6fae"
        case "audio": return "#ffcf5c"
        case "archive": return "#8fd18f"
        default: return root.cFaint
        }
    }
    function copyText(t) { clip.text = t; clip.selectAll(); clip.copy(); clip.deselect(); toast("Copied", false) }

    // ── toasts
    property string toastText: ""
    property bool toastBad: false
    function toast(t, bad) { root.toastText = t; root.toastBad = !!bad; toastTimer.restart() }
    Timer { id: toastTimer; interval: 4200; onTriggered: root.toastText = "" }

    Timer { interval: root.anyActive ? 700 : 4000; running: true; repeat: true; onTriggered: root.refresh() }
    Component.onCompleted: { registerViewDir(); refresh() }

    TextEdit { id: clip; visible: false }

    // ── layout
    Rectangle { anchors.fill: parent; color: root.cBg }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Servers
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 220
            color: root.cSurface
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root.sp * 1.5
                spacing: root.sp
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Dufs"; color: root.cText; font.pixelSize: 20; font.bold: true; textFormat: Text.PlainText; Layout.fillWidth: true }
                    Text { text: root.st.version ? "v" + root.st.version : ""; color: root.cFaint; font.pixelSize: 11; textFormat: Text.PlainText }
                }
                Text { text: "SERVERS"; color: root.cFaint; font.pixelSize: 11; font.letterSpacing: 1.2; textFormat: Text.PlainText; Layout.topMargin: root.sp }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 4
                    model: root.servers
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: 52
                        radius: 8
                        readonly property bool active: modelData.id === root.st.current
                        color: active ? root.cRaised : (sMouse.containsMouse ? Qt.darker(root.cRaised, 1.15) : "transparent")
                        border.width: active ? 1 : 0
                        border.color: root.cAccent
                        MouseArea { id: sMouse; anchors.fill: parent; hoverEnabled: true; onClicked: if (!parent.active) { root.selectedPath = ""; root.requested = ({}); root.act("selectServer", [modelData.id]) } }
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 34
                            spacing: 0
                            Item { Layout.fillHeight: true }
                            Text { text: modelData.name; color: root.cText; font.pixelSize: 14; font.bold: active; elide: Text.ElideRight; Layout.fillWidth: true; textFormat: Text.PlainText }
                            Text { text: modelData.url.replace(/^https?:\/\//, "") + (modelData.user ? "  ·  " + modelData.user : ""); color: root.cFaint; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true; textFormat: Text.PlainText }
                            Item { Layout.fillHeight: true }
                        }
                        Text {
                            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            text: "⋯"; color: root.cSub; font.pixelSize: 18; textFormat: Text.PlainText
                            MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: serverDialog.openFor(modelData) }
                        }
                    }
                }
                LogosButton { text: "+ Add server"; Layout.fillWidth: true; onClicked: serverDialog.openFor(null) }
            }
        }
        Rectangle { Layout.fillHeight: true; Layout.preferredWidth: 1; color: root.cLine }

        // Browser
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // toolbar
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                color: root.cBg
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: root.sp * 2
                    anchors.rightMargin: root.sp * 2
                    spacing: root.sp
                    // breadcrumb
                    Flickable {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 160
                        Layout.preferredHeight: 32
                        contentWidth: crumbs.width
                        clip: true
                        flickableDirection: Flickable.HorizontalFlick
                        Row {
                            id: crumbs
                            height: parent.height
                            spacing: 2
                            Repeater {
                                model: {
                                    if (!root.currentServer) return []
                                    var parts = (root.st.path || "/").split("/").filter(function (x) { return x !== "" })
                                    var out = [{ label: root.currentServer.name, path: "/" }], acc = "/"
                                    for (var i = 0; i < parts.length; i++) { acc += parts[i] + "/"; out.push({ label: parts[i], path: acc }) }
                                    return out
                                }
                                delegate: Row {
                                    required property var modelData
                                    required property int index
                                    height: crumbs.height
                                    Text { visible: index > 0; text: "  /  "; color: root.cFaint; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.label
                                        color: modelData.path === root.st.path ? root.cText : root.cSub
                                        font.pixelSize: 15
                                        font.bold: modelData.path === root.st.path
                                        textFormat: Text.PlainText
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openDir(modelData.path) }
                                    }
                                }
                            }
                        }
                    }
                    TextField {
                        id: searchField
                        Layout.preferredWidth: 180
                        Layout.preferredHeight: 34
                        visible: !!root.currentServer && root.st.perms && root.st.perms.search !== false
                        placeholderText: "Search here and below"
                        color: root.cText
                        placeholderTextColor: root.cFaint
                        font.pixelSize: 13
                        selectByMouse: true
                        background: Rectangle { radius: 6; color: root.cSurface; border.width: 1; border.color: searchField.activeFocus ? root.cAccent : root.cLine }
                        onAccepted: root.act("search", [text.trim()])
                        Connections { target: root; function onStChanged() { if (!searchField.activeFocus && (root.st.query || "") === "") searchField.text = "" } }
                    }
                    LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: root.gridMode ? "List" : "Grid"; enabled: !!root.currentServer; onClicked: root.gridMode = !root.gridMode }
                    LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: "New folder"; enabled: !!root.currentServer && !root.st.error && root.st.perms.upload === true && !root.st.query; onClicked: nameDialog.ask("New folder", "", function (n) { root.act("makeDir", [n]) }) }
                    LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: "Upload"; enabled: !!root.currentServer && !root.st.error && root.st.perms.upload === true && !root.st.query; onClicked: uploadDialog.open() }
                    LogosButton { Layout.preferredWidth: 44; Layout.preferredHeight: 34; text: "↻"; enabled: !!root.currentServer; onClicked: root.act("refresh", []) }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.cLine }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 40 : 0
                visible: root.coreLost
                color: Qt.darker(root.cBad, 1.8)
                Text {
                    anchors.fill: parent
                    anchors.leftMargin: root.sp * 2
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    color: root.cText
                    font.pixelSize: 13
                    text: "Dufs Core stopped responding. Restart Basecamp; if it keeps happening, remove the server you added last."
                }
            }

            // listing + preview
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Item {
                    id: listArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // column header (list mode)
                    Rectangle {
                        id: header
                        visible: !root.gridMode && !!root.currentServer && !root.st.error
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        height: visible ? 30 : 0
                        color: root.cBg
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: root.sp * 2 + 34
                            anchors.rightMargin: root.sp * 2
                            Repeater {
                                model: [{ k: "name", l: "Name", w: -1 }, { k: "size", l: "Size", w: 90 }, { k: "date", l: "Modified", w: 140 }]
                                delegate: Text {
                                    required property var modelData
                                    Layout.fillWidth: modelData.w < 0
                                    Layout.preferredWidth: modelData.w < 0 ? -1 : modelData.w
                                    horizontalAlignment: modelData.w < 0 ? Text.AlignLeft : Text.AlignRight
                                    text: modelData.l + (root.sortBy === modelData.k ? (root.sortDesc ? "  ↓" : "  ↑") : "")
                                    color: root.sortBy === modelData.k ? root.cSub : root.cFaint
                                    font.pixelSize: 11
                                    font.letterSpacing: 0.8
                                    textFormat: Text.PlainText
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (root.sortBy === modelData.k) root.sortDesc = !root.sortDesc; else { root.sortBy = modelData.k; root.sortDesc = modelData.k !== "name" } } }
                                }
                            }
                        }
                    }

                    // list mode
                    ListView {
                        id: listView
                        visible: !root.gridMode
                        anchors.fill: parent
                        anchors.topMargin: header.height
                        clip: true
                        model: root.sortedEntries
                        ScrollBar.vertical: ScrollBar {}
                        header: upRow
                        delegate: Rectangle {
                            required property var modelData
                            width: listView.width
                            height: 40
                            readonly property bool sel: modelData.path === root.selectedPath
                            color: sel ? root.cRaised : (rowMouse.containsMouse ? root.cSurface : "transparent")
                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (m) => { if (m.button === Qt.RightButton) { root.selectedPath = modelData.path; entryMenu.popupFor(modelData) } else if (modelData.dir) root.openDir(modelData.path); else root.activate(modelData) }
                            }
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: root.sp * 2
                                anchors.rightMargin: root.sp * 2
                                spacing: 12
                                Text { text: root.glyph(modelData.kind); color: root.kindColor(modelData.kind); font.pixelSize: 18; Layout.preferredWidth: 22; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text { text: modelData.name; color: root.cText; font.pixelSize: 14; elide: Text.ElideMiddle; Layout.fillWidth: true; textFormat: Text.PlainText }
                                    Text { visible: !!root.st.query && modelData.rel !== modelData.name; text: modelData.rel || ""; color: root.cFaint; font.pixelSize: 11; elide: Text.ElideMiddle; Layout.fillWidth: true; textFormat: Text.PlainText }
                                }
                                Text { text: root.fmtSize(modelData.size, modelData.dir); color: root.cSub; font.pixelSize: 12; Layout.preferredWidth: 90; horizontalAlignment: Text.AlignRight; textFormat: Text.PlainText }
                                Text { text: root.fmtDate(modelData.mtime); color: root.cFaint; font.pixelSize: 12; Layout.preferredWidth: 140; horizontalAlignment: Text.AlignRight; textFormat: Text.PlainText }
                            }
                        }
                    }

                    // grid mode
                    GridView {
                        id: gridView
                        visible: root.gridMode
                        anchors.fill: parent
                        anchors.margins: root.sp
                        clip: true
                        cellWidth: 160
                        cellHeight: 176
                        model: root.sortedEntries
                        ScrollBar.vertical: ScrollBar {}
                        header: upRow
                        delegate: Item {
                            required property var modelData
                            width: gridView.cellWidth
                            height: gridView.cellHeight
                            readonly property var pv: (root.st.previews || {})[modelData.path]
                            Component.onCompleted: if (modelData.kind === "image") root.wantPreview(modelData)
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 6
                                radius: 10
                                color: modelData.path === root.selectedPath ? root.cRaised : (cellMouse.containsMouse ? root.cSurface : "transparent")
                                border.width: modelData.path === root.selectedPath ? 1 : 0
                                border.color: root.cAccent
                                Rectangle {
                                    id: thumbBox
                                    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                                    anchors.margins: 8
                                    height: 112
                                    radius: 8
                                    color: root.cSurface
                                    clip: true
                                    Image {
                                        id: thumb
                                        anchors.fill: parent
                                        visible: status === Image.Ready
                                        source: (pv && pv.state === "ready" && pv.file) ? "file://" + pv.file : ""
                                        sourceSize.width: 288
                                        sourceSize.height: 224
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: !thumb.visible
                                        text: (pv && pv.state === "loading") ? "…" : root.glyph(modelData.kind)
                                        color: root.kindColor(modelData.kind)
                                        font.pixelSize: 40
                                        textFormat: Text.PlainText
                                    }
                                }
                                Text {
                                    anchors.top: thumbBox.bottom; anchors.topMargin: 8
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.leftMargin: 8; anchors.rightMargin: 8
                                    text: modelData.name
                                    color: root.cText
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    horizontalAlignment: Text.AlignHCenter
                                    textFormat: Text.PlainText
                                }
                                Text {
                                    anchors.bottom: parent.bottom; anchors.bottomMargin: 6
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.fmtSize(modelData.size, modelData.dir)
                                    color: root.cFaint
                                    font.pixelSize: 11
                                    textFormat: Text.PlainText
                                }
                                MouseArea {
                                    id: cellMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: (m) => { if (m.button === Qt.RightButton) { root.selectedPath = modelData.path; entryMenu.popupFor(modelData) } else root.activate(modelData) }
                                    onDoubleClicked: if (modelData.kind === "image") viewer.show(modelData)
                                }
                            }
                        }
                    }

                    Component {
                        id: upRow
                        Rectangle {
                            visible: !!root.currentServer && root.st.path !== "/" && !root.st.query
                            width: root.gridMode ? gridView.width : listView.width
                            height: visible ? 36 : 0
                            color: upMouse.containsMouse ? root.cSurface : "transparent"
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left; anchors.leftMargin: root.sp * 2 + 4
                                text: "←  Up one folder"
                                color: root.cSub
                                font.pixelSize: 13
                                textFormat: Text.PlainText
                            }
                            MouseArea { id: upMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.goUp() }
                        }
                    }

                    // empty / error / loading states
                    Column {
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 48, 460)
                        spacing: 12
                        visible: !root.currentServer || !!root.st.error || (!root.st.loading && (root.st.entries || []).length === 0)
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: root.st.error ? root.cBad : root.cText
                            font.pixelSize: 17
                            text: !root.coreSeen ? "Waiting for dufs_core..."
                                : !root.currentServer ? "Add a dufs server to start"
                                : root.st.error ? root.st.error
                                : root.st.query ? "Nothing matches “" + root.st.query + "”"
                                : "This folder is empty"
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: root.cFaint
                            font.pixelSize: 13
                            text: !root.coreSeen ? (root.missedPolls > 3 ? "No answer yet. Make sure the Dufs Core module is installed." : "")
                                : !root.currentServer ? "For example http://pi5.lan:5000. Start dufs with -A to allow uploads, deletes and search."
                                : root.st.error ? (root.currentServer ? root.currentServer.url : "")
                                : root.st.query ? "" : (root.st.perms.upload !== false ? "Drop files here to upload them." : "")
                        }
                        LogosButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: root.coreSeen && (!root.currentServer || !!root.st.error)
                            text: !root.currentServer ? "Add server" : "Try again"
                            onClicked: !root.currentServer ? serverDialog.openFor(null) : root.act("refresh", [])
                        }
                    }
                    Rectangle {
                        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                        height: 2
                        visible: !!root.st.loading
                        color: "transparent"
                        Rectangle {
                            id: loadBar
                            width: parent.width / 4; height: 2; color: root.cAccent
                            NumberAnimation on x { running: loadBar.visible; from: -loadBar.width; to: listArea.width; duration: 900; loops: Animation.Infinite }
                        }
                    }

                    // drag & drop upload
                    DropArea {
                        anchors.fill: parent
                        onEntered: (drag) => { root.dropHover = drag.hasUrls; if (drag.hasUrls) drag.accept(Qt.CopyAction) }
                        onExited: root.dropHover = false
                        onDropped: (drop) => { root.dropHover = false; if (drop.hasUrls) { drop.accept(Qt.CopyAction); root.uploadUrls(drop.urls) } }
                    }
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 8
                        visible: root.dropHover
                        radius: 12
                        color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.10)
                        border.width: 2
                        border.color: root.cAccent
                        Text {
                            anchors.centerIn: parent
                            text: "Drop to upload to " + (root.st.path || "/")
                            color: root.cText
                            font.pixelSize: 18
                            font.bold: true
                            textFormat: Text.PlainText
                        }
                    }
                }

                // preview pane
                Rectangle { visible: !!root.selectedEntry; Layout.fillHeight: true; Layout.preferredWidth: 1; color: root.cLine }
                Rectangle {
                    visible: !!root.selectedEntry
                    Layout.fillHeight: true
                    Layout.preferredWidth: 340
                    color: root.cSurface
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: root.sp * 2
                        spacing: root.sp
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: root.selectedEntry ? root.selectedEntry.name : ""; color: root.cText; font.pixelSize: 16; font.bold: true; wrapMode: Text.WrapAnywhere; maximumLineCount: 3; elide: Text.ElideRight; Layout.fillWidth: true; textFormat: Text.PlainText }
                            Text { text: "✕"; color: root.cSub; font.pixelSize: 15; textFormat: Text.PlainText; MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: root.selectedPath = "" } }
                        }
                        Text {
                            text: root.selectedEntry ? root.fmtSize(root.selectedEntry.size, false) + "  ·  " + root.fmtDate(root.selectedEntry.mtime) : ""
                            color: root.cFaint; font.pixelSize: 12; textFormat: Text.PlainText
                        }
                        // preview body
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: 8
                            color: root.cBg
                            clip: true
                            Image {
                                id: bigImg
                                anchors.fill: parent
                                anchors.margins: 6
                                visible: !!root.selectedEntry && root.selectedEntry.kind === "image" && status === Image.Ready
                                source: (root.selectedPreview && root.selectedPreview.file) ? "file://" + root.selectedPreview.file : ""
                                sourceSize.width: 1024
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: viewer.show(root.selectedEntry) }
                            }
                            ScrollView {
                                anchors.fill: parent
                                anchors.margins: 6
                                visible: !!root.selectedPreview && !!root.selectedPreview.text
                                TextArea {
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: TextArea.Wrap
                                    color: root.cText
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                    background: null
                                    text: root.selectedPreview && root.selectedPreview.text ? root.selectedPreview.text + (root.selectedPreview.truncated ? "\n\n[first 64 KB shown]" : "") : ""
                                }
                            }
                            Column {
                                anchors.centerIn: parent
                                width: parent.width - 32
                                spacing: 8
                                visible: !bigImg.visible && !(root.selectedPreview && root.selectedPreview.text)
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.selectedEntry ? root.glyph(root.selectedEntry.kind) : ""; color: root.selectedEntry ? root.kindColor(root.selectedEntry.kind) : root.cFaint; font.pixelSize: 54; textFormat: Text.PlainText }
                                Text {
                                    width: parent.width
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    color: root.cFaint
                                    font.pixelSize: 12
                                    textFormat: Text.PlainText
                                    text: !root.selectedPreview ? (root.selectedEntry && (root.selectedEntry.kind === "image" || root.selectedEntry.kind === "text") ? "Loading preview..." : "No preview for this kind of file")
                                        : root.selectedPreview.state === "loading" ? "Loading preview..."
                                        : (root.selectedPreview.error || "")
                                }
                            }
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: root.sp
                            rowSpacing: root.sp
                            LogosButton { Layout.fillWidth: true; text: "Download"; onClicked: { root.askSave(root.selectedEntry) } }
                            LogosButton { Layout.fillWidth: true; text: "Open in browser"; onClicked: Qt.openUrlExternally(root.selectedEntry.url) }
                            LogosButton { Layout.fillWidth: true; text: "Copy link"; onClicked: root.copyText(root.selectedEntry.url) }
                            LogosButton { Layout.fillWidth: true; text: "Rename"; enabled: root.st.perms.delete !== false; onClicked: { var e = root.selectedEntry; nameDialog.ask("Rename", e.name, function (n) { root.selectedPath = ""; root.act("renamePath", [e.path, n]) }) } }
                            LogosButton { Layout.fillWidth: true; Layout.columnSpan: 2; text: "Delete"; enabled: root.st.perms.delete !== false; onClicked: confirmDialog.ask(root.selectedEntry) }
                        }
                    }
                }
            }

            // transfers
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: (root.st.transfers || []).length ? Math.min(44 + (root.st.transfers || []).length * 34, 210) : 0
                visible: (root.st.transfers || []).length > 0
                color: root.cSurface
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: root.cLine }
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: root.sp * 1.5
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: root.activeTransfers ? "TRANSFERS  ·  " + root.activeTransfers + " active" : "TRANSFERS"; color: root.cFaint; font.pixelSize: 11; font.letterSpacing: 1.2; Layout.fillWidth: true; textFormat: Text.PlainText }
                        Text { text: "Clear finished"; color: root.cSub; font.pixelSize: 12; textFormat: Text.PlainText; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.act("clearTransfers", []) } }
                    }
                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 2
                        model: root.st.transfers || []
                        delegate: RowLayout {
                            required property var modelData
                            width: ListView.view.width
                            height: 30
                            spacing: 10
                            Text { text: modelData.kind === "upload" ? "↑" : "↓"; color: root.cSub; font.pixelSize: 14; textFormat: Text.PlainText }
                            Text { text: modelData.name; color: root.cText; font.pixelSize: 13; elide: Text.ElideMiddle; Layout.preferredWidth: 220; textFormat: Text.PlainText }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 6; radius: 3
                                color: root.cBg
                                Rectangle {
                                    height: parent.height; radius: 3
                                    width: parent.width * (modelData.total > 0 ? Math.min(1, modelData.done / modelData.total) : (modelData.state === "done" ? 1 : 0))
                                    color: modelData.state === "failed" ? root.cBad : (modelData.state === "done" ? root.cOk : root.cAccent)
                                }
                            }
                            Text {
                                Layout.preferredWidth: 230
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                font.pixelSize: 12
                                color: modelData.state === "failed" ? root.cBad : root.cSub
                                text: modelData.state === "failed" ? modelData.error
                                    : modelData.state === "done" ? (modelData.kind === "download" ? "Saved" : "Done") + "  ·  " + root.fmtSize(modelData.total, false)
                                    : modelData.state === "cancelled" ? "Cancelled"
                                    : modelData.state === "queued" ? "Waiting"
                                    : root.fmtSize(modelData.done, false) + " of " + root.fmtSize(modelData.total, false)
                            }
                            Text {
                                visible: modelData.state === "running" || modelData.state === "queued"
                                text: "✕"; color: root.cSub; font.pixelSize: 13; textFormat: Text.PlainText
                                MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: root.act("cancelTransfer", [modelData.id]) }
                            }
                        }
                    }
                }
            }
        }
    }

    // toast
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        visible: root.toastText !== ""
        width: Math.min(toastLabel.implicitWidth + 32, parent.width - 48)
        height: toastLabel.implicitHeight + 20
        radius: 10
        color: root.toastBad ? Qt.darker(root.cBad, 1.6) : root.cRaised
        border.width: 1
        border.color: root.toastBad ? root.cBad : root.cLine
        Text { id: toastLabel; anchors.centerIn: parent; width: parent.width - 32; text: root.toastText; color: root.cText; font.pixelSize: 13; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText }
    }

    // ── menus and dialogs
    Menu {
        id: entryMenu
        property var entry: null
        function popupFor(e) { entry = e; popup() }
        MenuItem { text: entryMenu.entry && entryMenu.entry.dir ? "Open" : "Preview"; onTriggered: root.activate(entryMenu.entry) }
        MenuItem { text: entryMenu.entry && entryMenu.entry.dir ? "Download as .zip" : "Download"; enabled: !(entryMenu.entry && entryMenu.entry.dir) || root.st.perms.archive !== false; onTriggered: { root.askSave(entryMenu.entry) } }
        MenuItem { text: "Copy link"; onTriggered: root.copyText(entryMenu.entry.url) }
        MenuItem { text: "Open in browser"; onTriggered: Qt.openUrlExternally(entryMenu.entry.url) }
        MenuSeparator {}
        MenuItem { text: "Rename"; enabled: root.st.perms.delete !== false; onTriggered: { var e = entryMenu.entry; nameDialog.ask("Rename", e.name, function (n) { root.act("renamePath", [e.path, n]) }) } }
        MenuItem { text: "Delete"; enabled: root.st.perms.delete !== false; onTriggered: confirmDialog.ask(entryMenu.entry) }
    }

    FileDialog {
        id: uploadDialog
        title: "Upload to " + (root.st.path || "/")
        fileMode: FileDialog.OpenFiles
        onAccepted: root.uploadUrls(uploadDialog.selectedFiles)
    }
    FileDialog {
        id: saveDialog
        property var target: null
        title: "Save " + (target ? target.name : "")
        fileMode: FileDialog.SaveFile
        onAccepted: if (target) root.act("download", [target.path, String(saveDialog.selectedFile)])
    }

    component DField: TextField {
        Layout.fillWidth: true
        color: root.cText
        placeholderTextColor: root.cFaint
        font.pixelSize: 14
        selectByMouse: true
        background: Rectangle { radius: 6; color: root.cBg; border.width: 1; border.color: parent.activeFocus ? root.cAccent : root.cLine }
    }
    component DLabel: Text { color: root.cSub; font.pixelSize: 12; textFormat: Text.PlainText }

    Popup {
        id: serverDialog
        property var editing: null
        function openFor(s) {
            editing = s
            sName.text = s ? s.name : ""
            sUrl.text = s ? s.url : ""
            sUser.text = s ? s.user : ""
            sPass.text = ""
            sPass.placeholderText = s && s.hasPassword ? "unchanged" : "optional"
            open()
            sUrl.forceActiveFocus()
        }
        function save() {
            if (sUrl.text.trim() === "") { root.toast("Enter the server address.", true); return }
            if (editing) {
                var cfg = { name: sName.text.trim(), url: sUrl.text.trim(), user: sUser.text.trim() }
                if (sPass.text !== "") cfg.password = sPass.text
                root.act("editServer", [editing.id, JSON.stringify(cfg)])
            } else {
                root.act("addServer", [sName.text.trim(), sUrl.text.trim(), sUser.text.trim(), sPass.text])
            }
            close()
        }
        anchors.centerIn: parent
        width: 420
        modal: true
        padding: 20
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 8
            Text { text: serverDialog.editing ? "Edit server" : "Add a dufs server"; color: root.cText; font.pixelSize: 17; font.bold: true; textFormat: Text.PlainText }
            DLabel { text: "Address"; Layout.topMargin: 6 }
            DField { id: sUrl; placeholderText: "http://pi5.lan:5000"; onAccepted: serverDialog.save() }
            DLabel { text: "Name" }
            DField { id: sName; placeholderText: "e.g. Pi5 (defaults to the host name)"; onAccepted: serverDialog.save() }
            DLabel { text: "Login (only if dufs runs with --auth)" }
            RowLayout {
                Layout.fillWidth: true
                DField { id: sUser; placeholderText: "user" }
                DField { id: sPass; placeholderText: "password"; echoMode: TextInput.Password; onAccepted: serverDialog.save() }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                LogosButton { visible: !!serverDialog.editing; text: "Remove"; onClicked: { var s = serverDialog.editing; serverDialog.close(); removeDialog.ask(s) } }
                Item { Layout.fillWidth: true }
                LogosButton { text: "Cancel"; onClicked: serverDialog.close() }
                LogosButton { text: serverDialog.editing ? "Save" : "Add"; onClicked: serverDialog.save() }
            }
        }
    }

    Popup {
        id: nameDialog
        property string title: ""
        property var cb: null
        function ask(t, initial, fn) { title = t; cb = fn; nField.text = initial; open(); nField.forceActiveFocus(); nField.selectAll() }
        function done() {
            var n = nField.text.trim()
            if (n === "" || n.indexOf("/") >= 0) { root.toast("Names cannot be empty or contain /.", true); return }
            close()
            if (cb) cb(n)
        }
        anchors.centerIn: parent
        width: 380
        modal: true
        padding: 20
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: nameDialog.title; color: root.cText; font.pixelSize: 17; font.bold: true; textFormat: Text.PlainText }
            DField { id: nField; onAccepted: nameDialog.done() }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                LogosButton { text: "Cancel"; onClicked: nameDialog.close() }
                LogosButton { text: "OK"; onClicked: nameDialog.done() }
            }
        }
    }

    Popup {
        id: confirmDialog
        property var entry: null
        function ask(e) { entry = e; open() }
        anchors.centerIn: parent
        width: 400
        modal: true
        padding: 20
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Delete " + (confirmDialog.entry ? confirmDialog.entry.name : "") + "?"; color: root.cText; font.pixelSize: 17; font.bold: true; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true; textFormat: Text.PlainText }
            Text {
                text: confirmDialog.entry && confirmDialog.entry.dir ? "The folder and everything in it is deleted from the server. This cannot be undone." : "The file is deleted from the server. This cannot be undone."
                color: root.cSub; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true; textFormat: Text.PlainText
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                LogosButton { text: "Cancel"; onClicked: confirmDialog.close() }
                LogosButton { text: "Delete"; onClicked: { var e = confirmDialog.entry; confirmDialog.close(); if (e.path === root.selectedPath) root.selectedPath = ""; root.act("removePath", [e.path]) } }
            }
        }
    }

    Popup {
        id: replaceDialog
        property var all: []
        property var clashes: []
        function ask(a, c) { all = a; clashes = c; open() }
        anchors.centerIn: parent
        width: 520
        modal: true
        padding: 20
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: replaceDialog.clashes.length === 1 ? "Replace " + root.baseOf(replaceDialog.clashes[0]) + "?" : "Replace " + replaceDialog.clashes.length + " files?"
                color: root.cText; font.pixelSize: 17; font.bold: true; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true; textFormat: Text.PlainText
            }
            Text {
                text: (replaceDialog.clashes.length === 1 ? "A file with this name" : "Files with these names") + " already exist" + (replaceDialog.clashes.length === 1 ? "s" : "") + " in " + (root.st.path || "/") + ". Uploading replaces " + (replaceDialog.clashes.length === 1 ? "it" : "them") + " on the server."
                color: root.cSub; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true; textFormat: Text.PlainText
            }
            RowLayout {
                Layout.fillWidth: true
                LogosButton { Layout.preferredWidth: 110; text: "Cancel"; onClicked: replaceDialog.close() }
                Item { Layout.fillWidth: true }
                LogosButton {
                    Layout.preferredWidth: 140
                    visible: replaceDialog.all.length > replaceDialog.clashes.length
                    text: "Skip existing"
                    onClicked: { var c = replaceDialog.clashes; var rest = replaceDialog.all.filter(function (u) { return c.indexOf(u) < 0 }); replaceDialog.close(); root.uploadNow(rest) }
                }
                LogosButton { Layout.preferredWidth: 110; text: "Replace"; onClicked: { var a = replaceDialog.all; replaceDialog.close(); root.uploadNow(a) } }
            }
        }
    }

    Popup {
        id: removeDialog
        property var server: null
        function ask(s) { server = s; open() }
        anchors.centerIn: parent
        width: 400
        modal: true
        padding: 20
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Remove " + (removeDialog.server ? removeDialog.server.name : "") + "?"; color: root.cText; font.pixelSize: 17; font.bold: true; textFormat: Text.PlainText }
            Text { text: "Only the entry in this list goes. Files on the server are not touched."; color: root.cSub; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true; textFormat: Text.PlainText }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                LogosButton { text: "Cancel"; onClicked: removeDialog.close() }
                LogosButton { text: "Remove"; onClicked: { var s = removeDialog.server; removeDialog.close(); root.selectedPath = ""; root.act("removeServer", [s.id]) } }
            }
        }
    }

    // full-size image viewer
    Rectangle {
        id: viewer
        property var entry: null
        function show(e) { if (!e) return; entry = e; root.wantPreview(e); visible = true; forceActiveFocus() }
        anchors.fill: parent
        visible: false
        color: Qt.rgba(0, 0, 0, 0.88)
        focus: visible
        Keys.onEscapePressed: visible = false
        readonly property var pv: entry ? (root.st.previews || {})[entry.path] : null
        MouseArea { anchors.fill: parent; onClicked: viewer.visible = false }
        Image {
            anchors.fill: parent
            anchors.margins: 40
            source: viewer.pv && viewer.pv.file ? "file://" + viewer.pv.file : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        Text {
            anchors.bottom: parent.bottom; anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            text: viewer.entry ? viewer.entry.name + "   ·   Esc or click to close" : ""
            color: "#d0d0d8"
            font.pixelSize: 13
            textFormat: Text.PlainText
        }
    }
}
