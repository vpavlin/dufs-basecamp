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
    // Pane widths, set by dragging the dividers (double-click one for its default).
    property real sideW: 220
    property real previewW: 340
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
    // Markdown files preview rendered; "source" shows the text as it is.
    property bool mdSource: false
    function isMarkdown(e) { return !!e && !e.dir && /\.(md|markdown|mdown|mkdn?)$/i.test(e.name || "") }
    function isHtml(e) { return !!e && !e.dir && /\.(html?|xhtml)$/i.test(e.name || "") }
    // An HTML file, for Qt's rich text: Qt's CSS subset (colours, fonts, alignment, margins, simple
    // backgrounds, tables), no CSS layout, no scripts. What could run or fetch is taken out first:
    // scripts, frames, embeds, forms, linked stylesheets, and in CSS every url() and @import. Images
    // become their alt text. Shown on a white page, as most pages assume one.
    function htmlForView(src) {
        function css(c) { return String(c).replace(/@import[^;]*;?/gi, "").replace(/url\s*\([^)]*\)/gi, "none").replace(/expression\s*\(/gi, "(") }
        var t = String(src || "")
        t = t.replace(/<!--[\s\S]*?-->/g, "")
        t = t.replace(/<(script|iframe|object|embed|noscript|template|svg|math|video|audio|canvas|form|select|textarea|button)\b[\s\S]*?<\/\1\s*>/gi, "")
        t = t.replace(/<(script|iframe|object|embed|link|meta|base|input|source|track|frame|frameset|param)\b[^>]*>/gi, "")
        t = t.replace(/<img\b[^>]*>/gi, function (m) { var a = m.match(/\balt\s*=\s*("([^"]*)"|'([^']*)')/i); return a ? (a[2] || a[3] || "") : "" })
        t = t.replace(/(<style\b[^>]*>)([\s\S]*?)(<\/style\s*>)/gi, function (m, o, c, e) { return o + css(c) + e })
        t = t.replace(/\sstyle\s*=\s*("([^"]*)"|'([^']*)')/gi, function (m, q, d, s1) { return ' style="' + css(d !== undefined ? d : s1).replace(/"/g, "'") + '"' })
        t = t.replace(/\s(background|src|srcset|on[a-z]+)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "")
        return t
    }
    // HTML in a real browser engine (Qt WebView), when Basecamp provides one; otherwise the rich-text
    // preview above. Locked down: JavaScript off, scripts/<base>/meta refresh stripped, and a CSP that
    // lets the page load only from its own Dufs server: no external scripts, styles, fonts, images,
    // frames or connections. A clicked link opens in the system browser, never inside the preview.
    property var webView: null
    property bool webTried: false
    property bool webOk: false
    property string webBase: ""
    property string webDoc: ""
    function originOf(u) { return (String(u || "").match(/^https?:\/\/[^\/?#]+/i) || [""])[0] }
    function webHtml(src, origin) {
        var t = String(src || "")
        t = t.replace(/<script\b[\s\S]*?<\/script\s*>/gi, "").replace(/<script\b[^>]*>/gi, "")
        t = t.replace(/<base\b[^>]*>/gi, "").replace(/<meta\b[^>]*http-equiv\s*=\s*["']?\s*refresh[^>]*>/gi, "")
        var self = origin ? " " + origin : ""
        var csp = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; "
            + "connect-src 'none'; form-action 'none'; base-uri 'none'; style-src 'unsafe-inline'" + self + "; img-src data:" + self
            + "; font-src data:" + self + "; media-src" + (self || " 'none'")
        var meta = '<meta http-equiv="Content-Security-Policy" content="' + csp + '">'
        return /<head\b[^>]*>/i.test(t) ? t.replace(/<head\b[^>]*>/i, function (m) { return m + meta }) : meta + t
    }
    function ensureWebView(host) {
        if (webTried) return webOk
        webTried = true
        try {
            webView = Qt.createQmlObject('import QtQuick; import QtWebView; WebView { anchors.fill: parent }', host, "dufsWebView")
            try {
                webView.settings.javaScriptEnabled = false
                webView.settings.localStorageEnabled = false
                webView.settings.allowFileAccess = false
                webView.settings.localContentCanAccessFileUrls = false
            } catch (e) { console.warn("Dufs: WebView settings unavailable: " + e) }
            webView.loadingChanged.connect(function (req) {
                var u = String(req.url || "")
                if (req.status !== 0) return   // WebView.LoadStartedStatus (QtWebView is not imported here)
                if (!u || u === "about:blank" || u === webBase || u.indexOf(webBase + "#") === 0 || u.indexOf("data:") === 0) return
                webView.stop()
                if (/^https?:/i.test(u)) openUrl(u)
                webView.loadHtml(webDoc, webBase)
            })
            webOk = true
        } catch (e) {
            console.warn("Dufs: no WebView here, HTML previews use rich text (" + e + ")")
            webView = null; webOk = false
        }
        return webOk
    }
    function showWeb(host, body, url) {
        if (!ensureWebView(host)) return
        webBase = String(url || ""); webDoc = webHtml(body, originOf(url))
        webView.loadHtml(webDoc, webBase)
    }

    // Markdown made into the rich text a Text shows. By hand rather than Qt's MarkdownText, which
    // paints links in the application palette's blue (unreadable here) and loads images: a file
    // shows without fetching anything, so images become their alt text and raw HTML shows as text.
    // CommonMark's common parts plus GitHub tables and ~~strike~~.
    function mdToHtml(src) {
        var link = root.cAccent, faint = root.cFaint, raised = root.cRaised, line = root.cLine
        function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;") }
        function a(href, label) { return '<a href="' + href + '"><span style="color:' + link + '">' + label + '</span></a>' }
        function inline(t) {
            var keep = []
            function stash(h) { keep.push(h); return "\u0000" + (keep.length - 1) + "\u0000" }
            t = t.replace(/`([^`]+)`/g, function (m, c) { return stash('<code style="background-color:' + raised + '">&nbsp;' + esc(c) + '&nbsp;</code>') })
            t = t.replace(/!\[([^\]]*)\]\([^)]*\)/g, function (m, alt) { return stash(esc(alt)) })
            t = t.replace(/\[([^\]]+)\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)/g, function (m, label, href) { return stash(a(esc(href), esc(label))) })
            t = t.replace(/<(https?:\/\/[^\s>]+)>/g, function (m, href) { return stash(a(esc(href), esc(href))) })
            t = t.replace(/(^|[\s(])(https?:\/\/[^\s<)]*[^\s<).,;:!?])/g, function (m, pre, href) { return pre + stash(a(esc(href), esc(href))) })
            t = esc(t)
            t = t.replace(/\*\*(\S(?:[^*]*\S)?)\*\*/g, "<b>$1</b>").replace(/__(\S(?:[^_]*\S)?)__/g, "<b>$1</b>")
            t = t.replace(/(^|[^\w*])\*(\S(?:[^*]*\S)?)\*/g, "$1<i>$2</i>").replace(/(^|[^\w])_(\S(?:[^_]*\S)?)_(?!\w)/g, "$1<i>$2</i>")
            t = t.replace(/~~(\S(?:[^~]*\S)?)~~/g, "<s>$1</s>")
            return t.replace(/\u0000(\d+)\u0000/g, function (m, i) { return keep[+i] })
        }
        function cells(l) { return l.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(function (c) { return c.trim() }) }
        var lines = String(src || "").replace(/\r/g, "").split("\n"), out = [], para = [], list = null
        function flush() { if (para.length) { out.push("<p>" + para.map(inline).join("<br>") + "</p>"); para = [] } }
        function closeList() { if (list) { out.push("</" + list + ">"); list = null } }
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i], m
            if ((m = l.match(/^\s{0,3}(```|~~~)/))) {
                flush(); closeList()
                var code = []
                for (i++; i < lines.length && lines[i].trim().indexOf(m[1]) !== 0; i++) code.push(lines[i])
                out.push('<table width="100%" cellpadding="8" style="background-color:' + raised + '"><tr><td><pre>' + esc(code.join("\n")) + "</pre></td></tr></table>")
                continue
            }
            if (/^\s*$/.test(l)) { flush(); closeList(); continue }
            if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(l)) { flush(); closeList(); out.push("<hr>"); continue }
            if ((m = l.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/))) {
                flush(); closeList()
                var n = Math.min(m[1].length, 4)
                out.push("<h" + n + ">" + inline(m[2]) + "</h" + n + ">")
                continue
            }
            if (/^\s*>/.test(l)) {
                flush(); closeList()
                var q = []
                for (; i < lines.length && /^\s*>/.test(lines[i]); i++) q.push(lines[i].replace(/^\s*>\s?/, ""))
                i--
                out.push('<table cellpadding="6"><tr><td style="color:' + faint + '">' + q.map(inline).join("<br>") + "</td></tr></table>")
                continue
            }
            if (/^\s*\|/.test(l) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
                flush(); closeList()
                var t = '<table cellspacing="0" cellpadding="6" border="1" style="border-color:' + line + '; border-style:solid">'
                t += "<tr>" + cells(l).map(function (c) { return "<th>" + inline(c) + "</th>" }).join("") + "</tr>"
                for (i += 2; i < lines.length && /^\s*\|/.test(lines[i]); i++)
                    t += "<tr>" + cells(lines[i]).map(function (c) { return "<td>" + inline(c) + "</td>" }).join("") + "</tr>"
                i--
                out.push(t + "</table>")
                continue
            }
            if ((m = l.match(/^\s*[-*+]\s+(.*)$/)) || (m = l.match(/^\s*\d+[.)]\s+(.*)$/))) {
                var kind = /^\s*\d/.test(l) ? "ol" : "ul"
                flush()
                if (list !== kind) { closeList(); out.push("<" + kind + ">"); list = kind }
                out.push("<li>" + inline(m[1].replace(/^\[ \]\s+/, "☐ ").replace(/^\[[xX]\]\s+/, "☑ ")) + "</li>")
                continue
            }
            if (list && /^\s{2,}\S/.test(l) && /<\/li>$/.test(out[out.length - 1])) {
                out[out.length - 1] = out[out.length - 1].replace(/<\/li>$/, "<br>" + inline(l.trim()) + "</li>")
                continue
            }
            closeList(); para.push(l)
        }
        flush(); closeList()
        return out.join("\n")
    }
    // A link in a rendered file: http(s) opens in the browser; a relative one is resolved against the file's own URL.
    function openMdLink(link) {
        var l = String(link || "")
        if (/^https?:\/\//i.test(l)) { openUrl(l); return }
        if (!l || l.charAt(0) === "#" || /^[a-z][a-z0-9+.-]*:/i.test(l) || !selectedEntry) return
        var base = String(selectedEntry.url || "")
        var origin = (base.match(/^https?:\/\/[^\/]+/i) || [""])[0]
        if (!origin) return
        openUrl(l.charAt(0) === "/" ? origin + l : base.replace(/[^\/]*$/, "") + l)
    }
    // The browser is opened by dufs_core: Basecamp's sandbox ignores a view's Qt.openUrlExternally.
    // If the core can't (an older core, no xdg-open), the link is copied instead.
    function openUrl(u) {
        callVia(coreName, "openUrl", [u], function (raw) {
            var o = parse(raw)
            if (o && o.ok === true) return
            copyText(u)
            toast("Couldn't open a browser, so the link is copied" + (o && o.error ? " (" + o.error + ")" : ""), true)
        })
    }
    property string sortBy: "name"
    property bool sortDesc: false
    property bool gridMode: false
    property var requested: ({})
    property bool dropHover: false
    // The core answered before and has now gone quiet: it stopped or crashed.
    readonly property bool coreLost: root.coreSeen && root.missedPolls >= 4

    readonly property var servers: st.servers || []
    // Logos Storage: shown in place of a server when picked in the sidebar.
    property bool storageMode: false
    readonly property var storage: st.storage || ({ state: "off", files: [] })
    readonly property string storageLine: {
        var s = root.storage, n = (s.files || []).length
        if (s.state === "error") return s.error || "Not available"
        if (s.state === "starting" || s.state === "off") return "Starting…"
        return n === 1 ? "1 file on this computer" : n + " files on this computer"
    }
    function openStorage() {
        root.storageMode = true
        root.selectedPath = ""
        act("storageRefresh", [])
    }
    function storeUrls(urls) {
        var list = []
        for (var i = 0; i < urls.length; i++) list.push(String(urls[i]))
        if (!list.length) return
        act("storageUpload", [JSON.stringify(list)], list.length === 1 ? "Putting 1 file into Storage" : "Putting " + list.length + " files into Storage")
    }
    function sendToStorage(e) {
        if (!e || e.dir || !root.st.current) return
        act("sendToStorage", [root.st.current, e.path], "Sending " + e.name + " to Logos Storage")
    }
    readonly property var currentServer: {
        for (var i = 0; i < servers.length; i++) if (servers[i].id === st.current) return servers[i]
        return null
    }
    readonly property bool anyActive: !!st.loading || activeTransfers > 0 || pendingPreviews > 0 || root.storage.state === "starting"
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
        if (root.pendingIntents.length) {
            var q = root.pendingIntents; root.pendingIntents = []
            for (var i = 0; i < q.length; i++) handleIntent(q[i][0], q[i][1], q[i][2])
        }
        selectPending()
    }
    // ── app-to-app intents: dufs.open {url} (Basecamp's intent broker, metadata.json "provides") ──
    // Another app, or a basecamp://intent/dufs.open?p=… link (`"web": true`), asks Dufs to show a file
    // or folder by its address. Dufs finds the server it is on, opens the folder and selects the
    // file. Every request is answered exactly once through logos.respond.
    property var pendingIntents: []
    property string pendingSelect: ""
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        ignoreUnknownSignals: true
        function onIntentRequested(requestId, intent, params, requesterName) {
            root.handleIntent(requestId, intent, params || ({}))
        }
    }
    function intentReply(requestId, ok, error) {
        try { logos.respond(requestId, ok, ({}), ok ? "" : (error || "failed")) }
        catch (e) { console.warn("dufs view: respond threw: " + e) }
    }
    function handleIntent(requestId, intent, p) {
        if (intent !== "dufs.open") { intentReply(requestId, false, "bad_request"); return }
        // Before the first snapshot the server list is unknown: answer once it arrives.
        if (!root.coreSeen) { var q = root.pendingIntents.slice(); q.push([requestId, intent, p]); root.pendingIntents = q; return }
        intentReply(requestId, openAddress(p.url) ? true : false, "bad_request")
    }
    // Opens a file or folder by its address: http(s) on a server Dufs knows, or a
    // basecamp://intent/dufs.open?p=… link. Says why in a toast when it can't; true when it opened.
    function openAddress(addr) {
        var u = String(addr || "").trim()
        var m = u.match(/^basecamp:\/\/intent\/dufs\.open\/?\?(?:.*&)?p=([A-Za-z0-9_\-=%]+)/i)
        if (m) {
            try {
                var b = decodeURIComponent(m[1]).replace(/-/g, "+").replace(/_/g, "/")
                while (b.length % 4) b += "="
                u = String(JSON.parse(decodeURIComponent(escape(Qt.atob(b)))).url || "").trim()
            } catch (e) { toast("That Basecamp link doesn't hold a Dufs address.", true); return false }
        }
        u = u.replace(/[?#].*$/, "")
        if (!/^https?:\/\//i.test(u)) { toast("Paste an http(s) address on a dufs server, or a Basecamp link from Dufs.", true); return false }
        var hit = null, best = -1
        var servers = root.st.servers || []
        for (var i = 0; i < servers.length; i++) {
            var sb = String(servers[i].url || "").replace(/\/+$/, "")
            if (!sb) continue
            var lu = u.toLowerCase(), lb = sb.toLowerCase()
            if ((lu === lb || lu.indexOf(lb + "/") === 0) && sb.length > best) { hit = servers[i]; best = sb.length }
        }
        if (!hit) {
            toast("Dufs has no server at " + (u.match(/^https?:\/\/[^\/]+/i) || [u])[0] + ". Add it, then open the address again.", true)
            return false
        }
        var path
        try { path = decodeURIComponent(u.substring(best)) } catch (e) { path = u.substring(best) }
        if (!path || path.charAt(0) !== "/") path = "/" + path
        openPlace(hit.id, path)
        return true
    }
    // Opens a path on a server: a folder ("/a/") is listed, a file ("/a/b.md") is selected in its folder.
    function openPlace(serverId, path) {
        var isDir = /\/$/.test(path)
        var dir = isDir ? path : path.substring(0, path.lastIndexOf("/") + 1)
        root.selectedPath = ""; root.requested = ({})
        root.pendingSelect = isDir ? "" : path
        var open = function () { callVia(coreName, "openDir", [dir], function (raw) { apply(parse(raw)) }) }
        if (root.st.current !== serverId) callVia(coreName, "selectServer", [serverId], function (raw) { apply(parse(raw)); open() })
        else open()
    }
    // After a dufs.open: select the file once its folder's listing is in.
    function selectPending() {
        if (!root.pendingSelect || root.st.loading) return
        var e = root.st.entries || []
        for (var i = 0; i < e.length; i++) if (e[i].path === root.pendingSelect) {
            root.pendingSelect = ""
            root.activate(e[i])
            return
        }
        if (root.st.path === root.pendingSelect.substring(0, root.pendingSelect.lastIndexOf("/") + 1)) {
            toast(root.baseName(root.pendingSelect) + " is no longer in this folder.", true)
            root.pendingSelect = ""
        }
    }
    // ── places: pinned and recently opened files/folders, kept by the core per server ──
    readonly property var pins: st.pins || []
    readonly property var recent: {
        // Recent leaves out what is already pinned.
        var p = {}, out = []
        root.pins.forEach(function (x) { p[x.server + "|" + x.path] = true })
        ;(st.recent || []).forEach(function (x) { if (!p[x.server + "|" + x.path]) out.push(x) })
        return out
    }
    function baseName(path) {
        var s = String(path || "").replace(/\/$/, "")
        return s.substring(s.lastIndexOf("/") + 1) || "/"
    }
    function serverName(id) {
        var s = root.servers
        for (var i = 0; i < s.length; i++) if (s[i].id === id) return s[i].name
        return ""
    }
    function isPinned(path) {
        for (var i = 0; i < root.pins.length; i++)
            if (root.pins[i].server === root.st.current && root.pins[i].path === path) return true
        return false
    }
    function togglePin(path) {
        if (!path || !root.st.current) return
        var on = isPinned(path)
        act(on ? "unpinPath" : "pinPath", [root.st.current, path], on ? "Unpinned " + baseName(path) : "Pinned " + baseName(path))
    }
    // A file the user opened goes to the top of Recent.
    function touch(path) { if (root.st.current && path) callVia(coreName, "touchPath", [root.st.current, path], function (raw) { var o = parse(raw); if (o && o.ok !== false) apply(o) }) }

    // A link that opens this file or folder in Dufs, from another app, a note or a browser:
    // basecamp://intent/dufs.open?p=<base64url of {"url": …}>.
    function basecampLink(url) {
        var b = Qt.btoa(unescape(encodeURIComponent(JSON.stringify({ url: String(url || "") }))))
        return "basecamp://intent/dufs.open?p=" + b.replace(/\+/g, "-").replace(/\//g, "_")
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
        touch(e.path)
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
    // A FRESH save dialog per download.
    //
    // Qt documents that `selectedFile` "can be set to control the file that is selected when
    // the dialog is opened" - and this used to set exactly that on a REUSED dialog. But a
    // reused dialog keeps the previous name in the native file picker, so downloading a second
    // file was offered the FIRST file's name (dufs-basecamp#1: "when I downloaded one file and
    // then tried to download another dufs would suggest the old name").
    //
    // Rather than depend on how the native layer caches its state, each download gets its own
    // dialog: `active` is cleared on close, so the next open constructs a new one with no
    // memory of the last name.
    function askSave(e) {
        if (!e) return
        // Drop any dialog that is already up. Without this, a second askSave while the first
        // dialog is open leaves the VISIBLE dialog showing the first file (Component.onCompleted
        // runs once), while `pending` has already moved on - so accepting it would download the
        // second file's content under the first file's approved name. (reviewer, 14/10)
        saveLoader.active = false
        // A fresh object every time, so `pending` always CHANGES - including when the same file
        // is downloaded twice in a row, which would otherwise not re-trigger anything.
        saveLoader.pending = { e: e }
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
    // Transfers that involve Logos Storage say which way they go.
    function transferGlyph(t) {
        switch (t.kind) {
        case "upload": return "↑"
        case "store": case "promote": return "⇢"
        case "demote": return "⇠"
        case "add": return "+"
        default: return "↓"
        }
    }
    function transferDone(t) {
        switch (t.kind) {
        case "download": case "fetch": return "Saved"
        case "store": case "promote": return "In Storage"
        case "demote": return "On " + root.serverName(t.server)
        case "add": return "Held here"
        default: return "Done"
        }
    }
    function transferStep(t) {
        if (t.kind === "promote") return t.phase === "http" ? "From the server: " : "Into Storage: "
        if (t.kind === "demote") return t.phase === "http" ? "To the server: " : "From Storage: "
        return ""
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
    // Ctrl+L: the address bar, holding this folder's address, selected to paste over.
    property bool addrEditing: false
    function startAddress() {
        if (!root.currentServer) return
        root.addrEditing = true
        var cur = String(root.currentServer.url || "").replace(/\/+$/, "") + encodeURI(root.st.path || "/")
        addrField.text = cur
        addrField.forceActiveFocus(); addrField.selectAll()
    }
    Shortcut { sequence: "Ctrl+L"; onActivated: root.startAddress() }
    // Ctrl+F (Cmd+F on a Mac): to the search box, its text selected to type over.
    Shortcut {
        sequence: StandardKey.Find
        enabled: searchField.visible
        onActivated: { searchField.forceActiveFocus(); searchField.selectAll() }
    }

    // A pane divider: a hairline with a wider grab area; drag to resize, double-click for the default.
    component Divider: Item {
        id: dv
        property real startW: 0
        signal dragged(real dx)
        signal pressedAt()
        signal reset()
        Layout.fillHeight: true
        Layout.preferredWidth: 1
        z: 10
        Rectangle { anchors.fill: parent; color: grab.pressed || grab.containsMouse ? root.cAccent : root.cLine }
        MouseArea {
            id: grab
            property real x0: 0
            anchors.fill: parent; anchors.leftMargin: -4; anchors.rightMargin: -4
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            onPressed: (m) => { x0 = mapToItem(root, m.x, 0).x; dv.pressedAt() }
            onPositionChanged: (m) => { if (pressed) dv.dragged(mapToItem(root, m.x, 0).x - x0) }
            onDoubleClicked: dv.reset()
        }
    }

    // ── layout
    Rectangle { anchors.fill: parent; color: root.cBg }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Servers
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: root.sideW
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
                    // Servers take what they need, up to 40% of the column; Pinned/Recent get the rest.
                    Layout.preferredHeight: Math.min(contentHeight, parent.height * 0.4)
                    clip: true
                    spacing: 4
                    model: root.servers
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: 52
                        radius: 8
                        readonly property bool active: modelData.id === root.st.current && !root.storageMode
                        color: active ? root.cRaised : (sMouse.containsMouse ? Qt.darker(root.cRaised, 1.15) : "transparent")
                        border.width: active ? 1 : 0
                        border.color: root.cAccent
                        MouseArea { id: sMouse; anchors.fill: parent; hoverEnabled: true; onClicked: if (!parent.active) { root.storageMode = false; root.selectedPath = ""; root.requested = ({}); if (modelData.id !== root.st.current) root.act("selectServer", [modelData.id]) } }
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
                // Logos Storage, as one more place beside the servers.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: root.sp
                    height: 52
                    radius: 8
                    color: root.storageMode ? root.cRaised : (lsMouse.containsMouse ? Qt.darker(root.cRaised, 1.15) : "transparent")
                    border.width: root.storageMode ? 1 : 0
                    border.color: root.cAccent
                    MouseArea { id: lsMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openStorage() }
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 0
                        Item { Layout.fillHeight: true }
                        Text { text: "Logos Storage"; color: root.cText; font.pixelSize: 14; font.bold: root.storageMode; elide: Text.ElideRight; Layout.fillWidth: true; textFormat: Text.PlainText }
                        Text {
                            text: root.storage.state === "off" ? "Files by CID, on this computer" : root.storageLine
                            color: root.storage.state === "error" ? root.cBad : root.cFaint; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true; textFormat: Text.PlainText
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                // Pinned and Recent: click to open; a pinned row's ✕ unpins, a recent row's ☆ pins it.
                ListView {
                    id: placesList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: root.sp
                    clip: true
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds
                    model: {
                        var m = []
                        if (root.pins.length) {
                            m.push({ hdr: "PINNED" })
                            root.pins.forEach(function (x) { m.push({ place: x, pinned: true }) })
                        }
                        if (root.recent.length) {
                            m.push({ hdr: "RECENT", clear: true })
                            root.recent.forEach(function (x) { m.push({ place: x, pinned: false }) })
                        }
                        if (!m.length && root.servers.length)
                            m.push({ hint: "Pin a file or folder from its ⋯ menu or the ☆ in the toolbar. Files you open show up here as Recent." })
                        return m
                    }
                    delegate: Item {
                        id: pRow
                        required property var modelData
                        width: ListView.view.width
                        height: modelData.hdr ? 28 : modelData.hint ? hintText.implicitHeight + 8 : 40
                        readonly property var pl: modelData.place || null
                        readonly property bool isDir: !!pl && /\/$/.test(pl.path)
                        readonly property bool here: !!pl && pl.server === root.st.current
                            && (isDir ? root.st.path === pl.path : root.selectedPath === pl.path)
                        Text {
                            id: hintText
                            visible: !!modelData.hint
                            width: parent.width
                            text: modelData.hint || ""
                            color: root.cFaint; font.pixelSize: 11; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                        }
                        RowLayout {
                            visible: !!modelData.hdr
                            anchors.fill: parent
                            Text { text: modelData.hdr || ""; color: root.cFaint; font.pixelSize: 11; font.letterSpacing: 1.2; textFormat: Text.PlainText; Layout.fillWidth: true; Layout.alignment: Qt.AlignBottom }
                            Text {
                                visible: !!modelData.clear
                                text: "Clear"; color: clearMouse.containsMouse ? root.cAccent : root.cFaint; font.pixelSize: 11; textFormat: Text.PlainText
                                Layout.alignment: Qt.AlignBottom
                                MouseArea { id: clearMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.act("forgetRecent", ["", ""]) }
                            }
                        }
                        Rectangle {
                            visible: !!pRow.pl
                            anchors.fill: parent
                            radius: 6
                            color: pRow.here ? root.cRaised : (pMouse.containsMouse ? Qt.darker(root.cRaised, 1.15) : "transparent")
                            MouseArea {
                                id: pMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.storageMode = false; root.openPlace(pRow.pl.server, pRow.pl.path) }
                            }
                            Text {
                                id: pGlyph
                                anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                width: 18
                                text: root.glyph(pRow.isDir ? "dir" : "")
                                color: root.kindColor(pRow.isDir ? "dir" : ""); font.pixelSize: 15; textFormat: Text.PlainText
                            }
                            ColumnLayout {
                                anchors.left: pGlyph.right; anchors.leftMargin: 6
                                anchors.right: parent.right; anchors.rightMargin: 28
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0
                                Text { text: pRow.pl ? root.baseName(pRow.pl.path) : ""; color: root.cText; font.pixelSize: 13; elide: Text.ElideMiddle; Layout.fillWidth: true; textFormat: Text.PlainText }
                                Text {
                                    text: {
                                        if (!pRow.pl) return ""
                                        var p = pRow.pl.path.replace(/\/$/, "")
                                        var dir = p.substring(0, p.lastIndexOf("/") + 1) || "/"
                                        return (root.servers.length > 1 ? root.serverName(pRow.pl.server) + "  ·  " : "") + dir
                                    }
                                    color: root.cFaint; font.pixelSize: 10; elide: Text.ElideLeft; Layout.fillWidth: true; textFormat: Text.PlainText
                                }
                            }
                            Text {
                                visible: pMouse.containsMouse || xMouse.containsMouse
                                anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                text: pRow.modelData.pinned ? "✕" : "☆"
                                color: xMouse.containsMouse ? root.cAccent : root.cSub; font.pixelSize: 13; textFormat: Text.PlainText
                                MouseArea {
                                    id: xMouse
                                    anchors.fill: parent; anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var x = pRow.pl
                                        if (pRow.modelData.pinned) root.act("unpinPath", [x.server, x.path], "Unpinned " + root.baseName(x.path))
                                        else root.act("pinPath", [x.server, x.path], "Pinned " + root.baseName(x.path))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        Divider { onDragged: (dx) => root.sideW = root.clamp(startW + dx, 160, Math.min(440, root.width - 520)); onPressedAt: startW = root.sideW; onReset: root.sideW = 220 }

        // Browser
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // toolbar
            Rectangle {
                visible: !root.storageMode
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                color: root.cBg
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: root.sp * 2
                    anchors.rightMargin: root.sp * 2
                    spacing: root.sp
                    // Go to an address: paste a file's http(s) address or a Basecamp link from Dufs.
                    TextField {
                        id: addrField
                        visible: root.addrEditing
                        Layout.fillWidth: true
                        Layout.minimumWidth: 160
                        Layout.preferredHeight: 34
                        placeholderText: "Paste a dufs address or a Basecamp link from Dufs, then Enter"
                        color: root.cText
                        placeholderTextColor: root.cFaint
                        font.pixelSize: 13
                        selectByMouse: true
                        background: Rectangle { radius: 6; color: root.cSurface; border.width: 1; border.color: addrField.activeFocus ? root.cAccent : root.cLine }
                        onAccepted: { if (root.openAddress(text)) root.addrEditing = false }
                        Keys.onEscapePressed: root.addrEditing = false
                        onActiveFocusChanged: if (!activeFocus) root.addrEditing = false
                    }
                    // breadcrumb
                    Flickable {
                        visible: !root.addrEditing
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
                        Layout.preferredWidth: 230
                        Layout.preferredHeight: 34
                        visible: !!root.currentServer && root.st.perms && root.st.perms.search !== false
                        placeholderText: "Search here and below (Ctrl+F)"
                        color: root.cText
                        placeholderTextColor: root.cFaint
                        font.pixelSize: 13
                        selectByMouse: true
                        background: Rectangle { radius: 6; color: root.cSurface; border.width: 1; border.color: searchField.activeFocus ? root.cAccent : root.cLine }
                        onAccepted: root.act("search", [text.trim()])
                        // Esc: clear the search and go back to the folder.
                        Keys.onEscapePressed: { clearSearch(); focus = false }
                        function clearSearch() { if (text !== "" || root.st.query) { text = ""; root.act("search", [""]) } }
                        rightPadding: clearX.visible ? 28 : leftPadding
                        // ✕: clear the search, back to the folder.
                        Text {
                            id: clearX
                            visible: searchField.text !== "" || !!root.st.query
                            anchors.right: parent.right; anchors.rightMargin: 9; anchors.verticalCenter: parent.verticalCenter
                            text: "✕"; color: clearMouse.containsMouse ? root.cText : root.cSub; font.pixelSize: 13; textFormat: Text.PlainText
                            MouseArea { id: clearMouse; anchors.fill: parent; anchors.margins: -7; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: searchField.clearSearch() }
                        }
                        Connections { target: root; function onStChanged() { if (!searchField.activeFocus && (root.st.query || "") === "") searchField.text = "" } }
                    }
                    // Pin the folder you're in.
                    LogosButton {
                        Layout.preferredWidth: 38; Layout.preferredHeight: 34
                        enabled: !!root.currentServer
                        readonly property bool on: root.isPinned(root.st.path || "/")
                        text: on ? "★" : "☆"
                        ToolTip.visible: hovered; ToolTip.delay: 500
                        ToolTip.text: on ? "Unpin this folder" : "Pin this folder"
                        onClicked: root.togglePin(root.st.path || "/")
                    }
                    LogosButton { Layout.preferredWidth: 80; Layout.preferredHeight: 34; text: "Go to…"; enabled: !!root.currentServer; onClicked: root.startAddress() }
                    LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: root.gridMode ? "List" : "Grid"; enabled: !!root.currentServer; onClicked: root.gridMode = !root.gridMode }
                    LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: "New folder"; enabled: !!root.currentServer && !root.st.error && root.st.perms.upload === true && !root.st.query; onClicked: nameDialog.ask("New folder", "", function (n) { root.act("makeDir", [n]) }) }
                    LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: "Upload"; enabled: !!root.currentServer && !root.st.error && root.st.perms.upload === true && !root.st.query; onClicked: uploadDialog.open() }
                    LogosButton { Layout.preferredWidth: 44; Layout.preferredHeight: 34; text: "↻"; enabled: !!root.currentServer; onClicked: root.act("refresh", []) }
                }
            }
            Rectangle { visible: !root.storageMode; Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.cLine }

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
                visible: !root.storageMode
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
                Divider { visible: !!root.selectedEntry; onDragged: (dx) => root.previewW = root.clamp(startW - dx, 260, root.width - root.sideW - 300); onPressedAt: startW = root.previewW; onReset: root.previewW = 340 }
                Rectangle {
                    visible: !!root.selectedEntry
                    Layout.fillHeight: true
                    Layout.preferredWidth: Math.min(root.previewW, Math.max(260, root.width - root.sideW - 300))
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
                        Row {
                            visible: (root.isMarkdown(root.selectedEntry) || root.isHtml(root.selectedEntry)) && !!root.selectedPreview && !!root.selectedPreview.text
                            spacing: 14
                            Repeater {
                                model: [{ label: "Rendered", src: false }, { label: "Source", src: true }]
                                Text {
                                    required property var modelData
                                    text: modelData.label; textFormat: Text.PlainText; font.pixelSize: 12
                                    color: root.mdSource === modelData.src ? root.cAccent : root.cSub
                                    font.bold: root.mdSource === modelData.src
                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.mdSource = modelData.src }
                                }
                            }
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
                                id: textScroll
                                readonly property string body: root.selectedPreview && root.selectedPreview.text ? root.selectedPreview.text : ""
                                readonly property bool cut: !!root.selectedPreview && !!root.selectedPreview.truncated
                                readonly property bool html: root.isHtml(root.selectedEntry)
                                readonly property bool rendered: (root.isMarkdown(root.selectedEntry) || html) && !root.mdSource
                                // HTML shows on a white page, as it was written for one.
                                background: Rectangle { radius: 6; color: textScroll.rendered && textScroll.html ? "#fbfbf9" : "transparent" }
                                anchors.fill: parent
                                anchors.margins: 6
                                visible: !!body && !webHost.visible
                                contentWidth: availableWidth
                                // Two children, so ScrollView can't size its content itself: say how tall it is.
                                contentHeight: rendered ? mdView.implicitHeight : plainView.implicitHeight
                                // Another file, or the other view: from the top.
                                onBodyChanged: contentItem.contentY = 0
                                onRenderedChanged: contentItem.contentY = 0
                                // As written: selectable, monospace.
                                TextArea {
                                    id: plainView
                                    visible: !textScroll.rendered
                                    width: textScroll.availableWidth
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: TextArea.Wrap
                                    color: root.cText
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                    background: null
                                    textFormat: TextEdit.PlainText
                                    text: textScroll.rendered || !textScroll.body ? "" : textScroll.body + (textScroll.cut ? "\n\n[first 64 KB shown]" : "")
                                }
                                // Markdown, rendered (Source has the text to select and copy).
                                Text {
                                    id: mdView
                                    visible: textScroll.rendered
                                    width: textScroll.availableWidth
                                    padding: 6
                                    wrapMode: Text.Wrap
                                    color: textScroll.html ? "#1d1d1f" : root.cText
                                    linkColor: textScroll.html ? "#1a5fb4" : root.cAccent
                                    font.pixelSize: 13
                                    textFormat: Text.RichText
                                    text: !textScroll.rendered || !textScroll.body ? ""
                                        : (textScroll.html ? root.htmlForView(textScroll.body) : root.mdToHtml(textScroll.body)) + (textScroll.cut ? "<hr><p><i>First 64 KB shown</i></p>" : "")
                                    onLinkActivated: (link) => root.openMdLink(link)
                                    HoverHandler { cursorShape: mdView.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
                                }
                            }
                            Item {
                                id: webHost
                                anchors.fill: parent
                                anchors.margins: 6
                                visible: textScroll.html && textScroll.rendered && !!textScroll.body && root.webOk
                                readonly property string key: textScroll.html && textScroll.rendered && textScroll.body
                                    ? root.selectedEntry.url + "|" + textScroll.body.length : ""
                                onKeyChanged: if (key) root.showWeb(webHost, textScroll.body, root.selectedEntry.url)
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
                            LogosButton { Layout.fillWidth: true; text: "Open in browser"; onClicked: root.openUrl(root.selectedEntry.url) }
                            LogosButton { Layout.fillWidth: true; text: "Copy link"; onClicked: root.copyText(root.selectedEntry.url) }
                            LogosButton { Layout.fillWidth: true; text: "Copy Basecamp link"; onClicked: root.copyText(root.basecampLink(root.selectedEntry.url)) }
                            LogosButton { Layout.fillWidth: true; text: "Rename"; enabled: root.st.perms.delete !== false; onClicked: { var e = root.selectedEntry; nameDialog.ask("Rename", e.name, function (n) { root.selectedPath = ""; root.act("renamePath", [e.path, n]) }) } }
                            LogosButton { Layout.fillWidth: true; text: "Delete"; enabled: root.st.perms.delete !== false; onClicked: confirmDialog.ask(root.selectedEntry) }
                            LogosButton { Layout.fillWidth: true; text: !!root.selectedEntry && root.isPinned(root.selectedEntry.path) ? "Unpin" : "Pin"; onClicked: root.togglePin(root.selectedEntry.path) }
                            LogosButton { Layout.fillWidth: true; text: "To Logos Storage"; onClicked: root.sendToStorage(root.selectedEntry) }
                        }
                    }
                }
            }

            // Logos Storage: what this computer's node holds
            ColumnLayout {
                visible: root.storageMode
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56
                    color: root.cBg
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: root.sp * 2
                        anchors.rightMargin: root.sp * 2
                        spacing: root.sp
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: "Logos Storage"; color: root.cText; font.pixelSize: 15; font.bold: true; textFormat: Text.PlainText }
                            Text {
                                text: root.storageLine
                                color: root.storage.state === "error" ? root.cBad : root.cFaint
                                font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true; textFormat: Text.PlainText
                            }
                        }
                        CheckBox {
                            id: announceBox
                            checked: root.storage.advertise !== false
                            onToggled: { root.act("storageSettings", [JSON.stringify({ advertise: checked })]); checked = Qt.binding(function () { return root.storage.advertise !== false }) }
                            ToolTip.visible: hovered; ToolTip.delay: 500
                            ToolTip.text: "Announce what you put into Storage, so others can fetch it by its CID. Off: it stays on this computer only."
                        }
                        Text {
                            text: "Announce"; color: root.cSub; font.pixelSize: 12; textFormat: Text.PlainText
                            Layout.leftMargin: -root.sp
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: announceBox.toggle(), announceBox.toggled() }
                        }
                        LogosButton { Layout.preferredWidth: 110; Layout.preferredHeight: 34; text: "Add by CID"; onClicked: cidDialog.open() }
                        LogosButton { Layout.preferredWidth: 96; Layout.preferredHeight: 34; text: "Upload"; onClicked: storageUploadDialog.open() }
                        LogosButton { Layout.preferredWidth: 44; Layout.preferredHeight: 34; text: "↻"; onClicked: root.act("storageRefresh", []) }
                    }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.cLine }
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    ListView {
                        id: storageList
                        anchors.fill: parent
                        clip: true
                        model: root.storage.files || []
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            width: storageList.width
                            height: 48
                            color: stMouse.containsMouse ? root.cSurface : "transparent"
                            MouseArea {
                                id: stMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: storageMenu.popupFor(modelData)
                            }
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: root.sp * 2
                                anchors.rightMargin: root.sp * 2
                                spacing: 12
                                Text { text: root.glyph(modelData.kind); color: root.kindColor(modelData.kind); font.pixelSize: 18; Layout.preferredWidth: 22; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text { text: modelData.name; color: root.cText; font.pixelSize: 14; elide: Text.ElideMiddle; Layout.fillWidth: true; textFormat: Text.PlainText }
                                    Text {
                                        text: (modelData.from ? (/^(added|by CID)/.test(modelData.from) ? modelData.from : "from " + modelData.from) + "  ·  " : "") + modelData.cid
                                        color: root.cFaint; font.pixelSize: 11; elide: Text.ElideMiddle; Layout.fillWidth: true; textFormat: Text.PlainText
                                    }
                                }
                                Text { text: root.fmtSize(modelData.size, false); color: root.cSub; font.pixelSize: 12; Layout.preferredWidth: 80; horizontalAlignment: Text.AlignRight; textFormat: Text.PlainText }
                                Text { text: modelData.at ? root.fmtDate(modelData.at) : ""; color: root.cFaint; font.pixelSize: 12; Layout.preferredWidth: 120; horizontalAlignment: Text.AlignRight; textFormat: Text.PlainText }
                                Text { text: "⋯"; color: root.cSub; font.pixelSize: 18; textFormat: Text.PlainText }
                            }
                        }
                    }
                    // empty, starting, error
                    Column {
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 48, 480)
                        spacing: 12
                        visible: (root.storage.files || []).length === 0
                        Text {
                            width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                            color: root.storage.state === "error" ? root.cBad : root.cText
                            font.pixelSize: 17
                            text: root.storage.state === "error" ? root.storage.error
                                : root.storage.state === "ready" ? "Nothing in Logos Storage yet"
                                : "Starting Logos Storage…"
                        }
                        Text {
                            width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                            color: root.cFaint; font.pixelSize: 13
                            visible: root.storage.state !== "starting"
                            text: root.storage.state === "error" ? "Basecamp starts Storage a moment after it opens. If this stays, check that the Storage module is installed."
                                : "Drop files here, upload them, send a file from a dufs server (its ⋯ menu), or add one someone shared by its CID."
                        }
                        LogosButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: root.storage.state === "error"
                            text: "Try again"
                            onClicked: root.act("storageRefresh", [])
                        }
                    }
                    DropArea {
                        anchors.fill: parent
                        onEntered: (drag) => { root.dropHover = drag.hasUrls; if (drag.hasUrls) drag.accept(Qt.CopyAction) }
                        onExited: root.dropHover = false
                        onDropped: (drop) => { root.dropHover = false; if (drop.hasUrls) { drop.accept(Qt.CopyAction); root.storeUrls(drop.urls) } }
                    }
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 8
                        visible: root.dropHover && root.storageMode
                        radius: 12
                        color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.10)
                        border.width: 2
                        border.color: root.cAccent
                        Text { anchors.centerIn: parent; text: "Drop to put into Logos Storage"; color: root.cText; font.pixelSize: 18; font.bold: true; textFormat: Text.PlainText }
                    }
                }
                // What sharing through Storage means, once, where it applies.
                Text {
                    Layout.fillWidth: true
                    Layout.margins: root.sp * 2
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    color: root.cFaint
                    font.pixelSize: 11
                    text: root.storage.advertise !== false
                        ? "Anyone with a file's CID can fetch it from this computer while it is online and reachable, so Storage is public to whoever you give the CID. Keep private files on your dufs servers."
                        : "Not announcing: what you put in now stays on this computer, and others can't fetch it."
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
                            Text { text: root.transferGlyph(modelData); color: root.cSub; font.pixelSize: 14; textFormat: Text.PlainText; Layout.preferredWidth: 16 }
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
                                    : modelData.state === "done" ? root.transferDone(modelData) + "  ·  " + root.fmtSize(modelData.total, false)
                                    : modelData.state === "cancelled" ? "Cancelled"
                                    : modelData.state === "queued" ? "Waiting"
                                    : root.transferStep(modelData) + (modelData.total > 0 ? root.fmtSize(modelData.done, false) + " of " + root.fmtSize(modelData.total, false) : "finding it…")
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
        MenuItem { text: "Copy Basecamp link"; onTriggered: root.copyText(root.basecampLink(entryMenu.entry.url)) }
        MenuItem { text: entryMenu.entry && root.isPinned(entryMenu.entry.path) ? "Unpin" : "Pin"; onTriggered: root.togglePin(entryMenu.entry.path) }
        MenuItem { text: "Open in browser"; onTriggered: root.openUrl(entryMenu.entry.url) }
        MenuItem { text: "Send to Logos Storage"; enabled: !!entryMenu.entry && !entryMenu.entry.dir; onTriggered: root.sendToStorage(entryMenu.entry) }
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
    Loader {
        id: saveLoader
        property var pending: null
        active: false
        sourceComponent: saveComp
        onPendingChanged: {
            if (!pending) return
            active = true                       // constructs a NEW dialog (active was cleared on close)
            if (item) item.open()
        }
    }
    Component {
        id: saveComp
        FileDialog {
            fileMode: FileDialog.SaveFile
            // The entry THIS dialog was opened for, captured once. `pending` is shared mutable
            // state; if it moved on, acting on it would pair one file's path with another's
            // chosen name. Capturing makes that pairing impossible by construction.
            property var myEntry: null
            // Set the pre-selection BEFORE open(), as Qt documents - on a dialog that has
            // never been used before, so there is nothing stale to prefer.
            Component.onCompleted: {
                var p = saveLoader.pending
                if (!p) return
                myEntry = p.e
                var dir = root.st.downloadsDir || ""
                var name = p.e.name + (p.e.dir ? ".zip" : "")
                title = "Save " + p.e.name
                if (dir) currentFolder = root.fileUrl(dir)
                selectedFile = root.fileUrl((dir ? dir : "") + "/" + name)
            }
            // QtQuick.Dialogs.FileDialog has exactly two signals, accepted() and rejected() -
            // there is NO `closed`. (QtQuick.Controls Dialog, used elsewhere in this file, does
            // have one; FileDialog is a separate, older hierarchy that never gained it. Hooking
            // onClosed here failed to load the whole view: reviewer, 14/10.)
            onAccepted: {
                var e = myEntry
                saveLoader.active = false            // destroy before acting; a re-entrant askSave cannot reach this dialog
                if (e && e.cid) root.act("storageDownload", [e.cid, String(selectedFile)])
                else if (e) root.act("download", [e.path, String(selectedFile)])
            }
            onRejected: saveLoader.active = false
        }
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


    // ── Logos Storage: menus and dialogs
    Menu {
        id: storageMenu
        property var file: null
        function popupFor(f) { file = f; popup() }
        MenuItem { text: "Download…"; onTriggered: root.askSave({ name: storageMenu.file.name, cid: storageMenu.file.cid, dir: false }) }
        MenuItem { text: "Save to a dufs server…"; enabled: root.servers.length > 0; onTriggered: toServerDialog.ask(storageMenu.file) }
        MenuItem { text: "Copy CID"; onTriggered: root.copyText(storageMenu.file.cid) }
        MenuSeparator {}
        MenuItem { text: "Remove from Storage"; onTriggered: root.act("storageRemove", [storageMenu.file.cid]) }
    }
    FileDialog {
        id: storageUploadDialog
        title: "Put into Logos Storage"
        fileMode: FileDialog.OpenFiles
        onAccepted: root.storeUrls(storageUploadDialog.selectedFiles)
    }
    Popup {
        id: cidDialog
        anchors.centerIn: parent
        width: 460
        modal: true
        padding: 20
        onOpened: { cidField.text = ""; cidField.forceActiveFocus() }
        function done() {
            var c = cidField.text.trim()
            if (!c) return
            close()
            root.act("storageAdd", [c], "Fetching it from Storage")
        }
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Add by CID"; color: root.cText; font.pixelSize: 17; font.bold: true; textFormat: Text.PlainText }
            Text {
                text: "A CID someone shared. This computer fetches the file and keeps it, and serves it too while announcing."
                color: root.cSub; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true; textFormat: Text.PlainText
            }
            DField { id: cidField; placeholderText: "zDvZ…"; onAccepted: cidDialog.done() }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                LogosButton { text: "Cancel"; onClicked: cidDialog.close() }
                LogosButton { text: "Add"; onClicked: cidDialog.done() }
            }
        }
    }
    Popup {
        id: toServerDialog
        property var file: null
        function ask(f) {
            file = f
            var cur = -1
            for (var i = 0; i < root.servers.length; i++) if (root.servers[i].id === root.st.current) cur = i
            serverBox.currentIndex = Math.max(0, cur)
            dirField.text = cur >= 0 ? (root.st.path || "/") : "/"
            open()
        }
        function done() {
            var s = root.servers[serverBox.currentIndex]
            if (!s || !file) return
            var dir = dirField.text.trim() || "/"
            if (dir.charAt(0) !== "/") dir = "/" + dir
            close()
            root.act("saveToServer", [file.cid, s.id, dir], "Saving " + file.name + " to " + s.name)
        }
        anchors.centerIn: parent
        width: 440
        modal: true
        padding: 20
        background: Rectangle { radius: 12; color: root.cSurface; border.width: 1; border.color: root.cLine }
        contentItem: ColumnLayout {
            spacing: 8
            Text { text: "Save " + (toServerDialog.file ? toServerDialog.file.name : "") + " to a server"; color: root.cText; font.pixelSize: 17; font.bold: true; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true; textFormat: Text.PlainText }
            DLabel { text: "Server"; Layout.topMargin: 6 }
            ComboBox {
                id: serverBox
                Layout.fillWidth: true
                model: root.servers.map(function (s) { return s.name })
                onActivated: dirField.text = root.servers[currentIndex] && root.servers[currentIndex].id === root.st.current ? (root.st.path || "/") : "/"
            }
            DLabel { text: "Folder" }
            DField { id: dirField; placeholderText: "/"; onAccepted: toServerDialog.done() }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Item { Layout.fillWidth: true }
                LogosButton { text: "Cancel"; onClicked: toServerDialog.close() }
                LogosButton { text: "Save"; onClicked: toServerDialog.done() }
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
