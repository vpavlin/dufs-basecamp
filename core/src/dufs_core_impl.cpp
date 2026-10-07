#include "dufs_core_impl.h"

#include <QByteArray>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QUuid>

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <memory>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <vector>

using json = nlohmann::json;
namespace fs = std::filesystem;

static const char* kVersion = "0.1.1";
static const qint64 kMaxImagePreview = 30LL * 1024 * 1024;
static const qint64 kTextPreviewBytes = 64 * 1024;
static const int kMaxPreviewJobs = 3;
static const int kMaxUploadJobs = 2;
static const qint64 kCacheLimit = 400LL * 1024 * 1024;

// ── helpers ─────────────────────────────────────────────────────────────────

static std::string dataDir()
{
    if (const char* e = std::getenv("DUFS_CORE_DATA")) if (*e) return e;
    if (const char* h = std::getenv("HOME")) if (*h) return std::string(h) + "/.dufs-basecamp";
    return "/tmp/.dufs-basecamp";
}

// Typed reads that never throw. json::value() throws on a field of another type, and a reply from a
// server (or anything on the path of a plain-http connection) can have any shape.
static std::string jstr(const json& o, const char* k, const std::string& def)
{
    if (!o.is_object()) return def;
    auto it = o.find(k);
    return (it != o.end() && it->is_string()) ? it->get<std::string>() : def;
}
static int64_t jnum(const json& o, const char* k, int64_t def)
{
    if (!o.is_object()) return def;
    auto it = o.find(k);
    if (it == o.end() || !it->is_number()) return def;
    return it->is_number_float() ? (int64_t)it->get<double>() : it->get<int64_t>();
}
static bool jbool(const json& o, const char* k, bool def)
{
    if (!o.is_object()) return def;
    auto it = o.find(k);
    return (it != o.end() && it->is_boolean()) ? it->get<bool>() : def;
}

// Every network callback runs inside a Qt signal: an exception escaping it terminates the whole
// module process. Wrap them all; log what was swallowed.
template <typename F>
static auto guarded(const char* where, F fn)
{
    return [where, fn](auto&&... args) mutable {
        try { fn(std::forward<decltype(args)>(args)...); }
        catch (const std::exception& e) { std::fprintf(stderr, "[dufs_core] %s: %s\n", where, e.what()); }
        catch (...) { std::fprintf(stderr, "[dufs_core] %s: unknown exception\n", where); }
    };
}

static json readJsonFile(const std::string& path)
{
    std::ifstream f(path);
    if (!f) return json();
    std::stringstream ss; ss << f.rdbuf();
    return json::parse(ss.str(), nullptr, false);
}

// Atomic write, owner-only from the first byte (the file can hold server passwords).
static void writeJsonFile(const std::string& path, const json& j)
{
    const std::string tmp = path + ".tmp";
    const std::string body = j.dump(2);
    int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    ::fchmod(fd, 0600);
    size_t off = 0;
    while (off < body.size()) {
        ssize_t n = ::write(fd, body.data() + off, body.size() - off);
        if (n <= 0) { ::close(fd); ::unlink(tmp.c_str()); return; }
        off += (size_t)n;
    }
    ::close(fd);
    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) fs::remove(tmp, ec);
}

static void ensurePrivateDir(const std::string& d)
{
    std::error_code ec;
    fs::create_directories(d, ec);
    fs::permissions(d, fs::perms::owner_all, fs::perm_options::replace, ec);
}

static std::string lower(std::string s)
{
    for (auto& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

static std::string extOf(const std::string& name)
{
    auto dot = name.find_last_of('.');
    if (dot == std::string::npos || dot == 0) return "";
    return lower(name.substr(dot + 1));
}

static std::string kindOf(const std::string& name, bool dir)
{
    if (dir) return "dir";
    static const std::vector<std::string> img = {"jpg","jpeg","png","gif","webp","bmp","svg","ico"};
    static const std::vector<std::string> txt = {"txt","md","json","yaml","yml","toml","ini","cfg","conf","log","csv","tsv",
        "xml","html","htm","css","js","ts","tsx","jsx","mjs","py","rs","go","c","h","cpp","hpp","cc","java","kt","sh","bash",
        "nix","qml","sql","lua","rb","php","swift","env","gitignore","dockerfile","service","lock"};
    static const std::vector<std::string> vid = {"mp4","mkv","webm","mov","avi","m4v"};
    static const std::vector<std::string> aud = {"mp3","flac","ogg","opus","wav","m4a","aac"};
    static const std::vector<std::string> arc = {"zip","tar","gz","tgz","xz","bz2","7z","rar","zst","lgx","apk","deb"};
    static const std::vector<std::string> doc = {"pdf","odt","docx","doc","xlsx","ods","pptx","odp","epub"};
    const std::string e = extOf(name);
    auto in = [&](const std::vector<std::string>& v) { for (auto& x : v) if (x == e) return true; return false; };
    if (in(img)) return "image";
    if (in(txt)) return "text";
    if (in(vid)) return "video";
    if (in(aud)) return "audio";
    if (in(arc)) return "archive";
    if (in(doc)) return "document";
    const std::string n = lower(name);
    if (n == "readme" || n == "license" || n == "makefile" || n == "dockerfile") return "text";
    return "file";
}

// "/a/b" -> "/a/b/" ; "" -> "/"
static std::string normDir(std::string p)
{
    if (p.empty() || p[0] != '/') p = "/" + p;
    if (p.back() != '/') p += "/";
    return p;
}

static std::string parentOf(const std::string& path)
{
    std::string p = path;
    if (p.size() > 1 && p.back() == '/') p.pop_back();
    auto slash = p.find_last_of('/');
    if (slash == std::string::npos) return "/";
    return p.substr(0, slash + 1);
}

static std::string baseName(const std::string& path)
{
    std::string p = path;
    if (p.size() > 1 && p.back() == '/') p.pop_back();
    auto slash = p.find_last_of('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

static std::string localPathFrom(std::string p)
{
    if (p.rfind("file://", 0) == 0) return QUrl(QString::fromStdString(p)).toLocalFile().toStdString();
    return p;
}

static std::string httpError(QNetworkReply* r)
{
    const QString moved = r->property("dufsRedirect").toString();
    if (!moved.isEmpty())
        return "The server redirected to another address (" + moved.toStdString() +
               "). Not followed, so your login is not sent there. Add that address as a server if you trust it.";
    const int code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    switch (code) {
        case 401: return "The server wants a login, or the user name or password is wrong.";
        case 403: return "The server does not allow this (check its --allow-* flags or your login).";
        case 404: return "Not found on the server. It may have been moved or deleted.";
        case 409: return "Conflict: something with that name already exists.";
        case 413: return "The server refused the file as too large.";
        default: break;
    }
    if (code >= 400) return "The server answered HTTP " + std::to_string(code) + ".";
    switch (r->error()) {
        case QNetworkReply::ConnectionRefusedError: return "Connection refused. Is dufs running on that address and port?";
        case QNetworkReply::HostNotFoundError: return "Host not found. Check the server address.";
        case QNetworkReply::TimeoutError:
        case QNetworkReply::OperationCanceledError: return "The server did not answer in time.";
        default: break;
    }
    return r->errorString().toStdString();
}

// ── state ───────────────────────────────────────────────────────────────────

struct Server {
    std::string id, name, url, user, password, lastPath = "/";
};

struct Transfer {
    std::string id, kind, name, path, local, state = "queued", error;
    qint64 done = 0, total = 0;
    QPointer<QNetworkReply> reply;
    QFile* file = nullptr;
    std::string serverId, dir;
};

struct Preview {
    std::string state, file, text, error;
    bool truncated = false;
};

struct DufsCorePrivate {
    DufsCoreImpl* q;
    QNetworkAccessManager* nam = nullptr;
    std::vector<Server> servers;
    std::string currentId;

    // listing of the current folder
    std::string path = "/";
    std::string query;
    bool loading = false;
    std::string listError;
    json entries = json::array();
    json perms = json::object();
    quint64 listGen = 0;
    QPointer<QNetworkReply> listReply;

    std::string notice, noticeKind;
    qint64 noticeAt = 0;

    std::vector<Transfer> transfers;
    std::map<std::string, Preview> previews;
    std::deque<std::string> previewQueue;
    int previewJobs = 0;
    std::string viewDir;

    bool emitPending = false;

    explicit DufsCorePrivate(DufsCoreImpl* qq) : q(qq) {}

    QNetworkAccessManager* net()
    {
        if (!nam) nam = new QNetworkAccessManager();
        return nam;
    }

    Server* current()
    {
        for (auto& s : servers) if (s.id == currentId) return &s;
        return nullptr;
    }
    Server* find(const std::string& id)
    {
        for (auto& s : servers) if (s.id == id) return &s;
        return nullptr;
    }

    // ── persistence
    std::string serversFile() const { return dataDir() + "/servers.json"; }
    void load()
    {
        ensurePrivateDir(dataDir());
        json j = readJsonFile(serversFile());
        if (!j.is_object()) return;
        auto it = j.find("servers");
        if (it != j.end() && it->is_array()) {
            for (auto& s : *it) {
                if (!s.is_object()) continue;
                Server sv;
                sv.id = jstr(s, "id", ""); sv.name = jstr(s, "name", ""); sv.url = jstr(s, "url", "");
                sv.user = jstr(s, "user", ""); sv.password = jstr(s, "password", "");
                sv.lastPath = jstr(s, "lastPath", "/");
                if (!sv.id.empty() && !sv.url.empty()) servers.push_back(sv);
            }
        }
        currentId = jstr(j, "current", "");
        if (!find(currentId)) currentId = servers.empty() ? "" : servers.front().id;
        if (auto* s = current()) path = normDir(s->lastPath);
    }
    void save()
    {
        json arr = json::array();
        for (auto& s : servers)
            arr.push_back({{"id", s.id}, {"name", s.name}, {"url", s.url}, {"user", s.user},
                           {"password", s.password}, {"lastPath", s.lastPath}});
        writeJsonFile(serversFile(), {{"servers", arr}, {"current", currentId}});
    }

    // ── URLs / requests
    static std::string normUrl(std::string u)
    {
        while (!u.empty() && (u.back() == ' ' || u.back() == '\n')) u.pop_back();
        while (!u.empty() && u.front() == ' ') u.erase(0, 1);
        if (u.find("://") == std::string::npos) u = "http://" + u;
        while (u.size() > 8 && u.back() == '/') u.pop_back();
        return u;
    }
    QUrl urlFor(const Server& s, const std::string& p) const
    {
        QUrl u(QString::fromStdString(s.url));
        QString base = u.path(QUrl::FullyDecoded);
        while (base.endsWith('/')) base.chop(1);
        u.setPath(base + QString::fromStdString(p), QUrl::DecodedMode);
        return u;
    }
    std::string publicUrl(const Server& s, const std::string& p) const
    {
        return urlFor(s, p).toString(QUrl::FullyEncoded).toStdString();
    }
    QNetworkRequest request(const Server& s, const QUrl& u, int timeoutMs) const
    {
        QNetworkRequest r(u);
        // Redirects are checked per reply (watch()): only within the same scheme, host and port,
        // because the login travels as a header and must never reach another host.
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::UserVerifiedRedirectPolicy);
        r.setTransferTimeout(timeoutMs);
        if (!s.user.empty()) {
            QByteArray cred = QByteArray::fromStdString(s.user + ":" + s.password).toBase64();
            r.setRawHeader("Authorization", "Basic " + cred);
        }
        return r;
    }

    // Follow a redirect only if it stays on the same origin as the request; otherwise stop with an
    // error the user can read (httpError picks up the "dufsRedirect" property).
    QNetworkReply* watch(QNetworkReply* r)
    {
        const QUrl origin = r->request().url();
        QObject::connect(r, &QNetworkReply::redirected, guarded("redirect", [r, origin](const QUrl& to) {
            const QUrl dest = origin.resolved(to);
            if (dest.scheme() == origin.scheme() && dest.host() == origin.host()
                && dest.port(origin.scheme() == "https" ? 443 : 80) == origin.port(origin.scheme() == "https" ? 443 : 80)) {
                r->redirectAllowed();
            } else {
                r->setProperty("dufsRedirect", dest.toString(QUrl::RemoveUserInfo | QUrl::RemoveQuery));
                r->abort();
            }
        }));
        return r;
    }

    // ── notices + state push
    void note(const std::string& msg, const std::string& kind)
    {
        notice = msg; noticeKind = kind; noticeAt = QDateTime::currentMSecsSinceEpoch();
    }
    void changed()
    {
        // Coalesce bursts (upload progress) into one push per ~250 ms.
        if (emitPending) return;
        emitPending = true;
        QTimer::singleShot(250, [this] { emitPending = false; q->stateChanged(state().dump()); });
    }

    json state()
    {
        json sv = json::array();
        for (auto& s : servers)
            sv.push_back({{"id", s.id}, {"name", s.name}, {"url", s.url}, {"user", s.user},
                          {"hasPassword", !s.password.empty()}});
        json tr = json::array();
        for (auto& t : transfers)
            tr.push_back({{"id", t.id}, {"kind", t.kind}, {"name", t.name}, {"path", t.path}, {"local", t.local},
                          {"state", t.state}, {"error", t.error}, {"done", t.done}, {"total", t.total}});
        json pv = json::object();
        for (auto& [k, p] : previews) {
            json o = {{"state", p.state}};
            if (!p.file.empty()) o["file"] = p.file;
            if (!p.text.empty()) o["text"] = p.text;
            if (!p.error.empty()) o["error"] = p.error;
            if (p.truncated) o["truncated"] = true;
            pv[k] = o;
        }
        Server* s = current();
        return {
            {"ok", true},
            {"version", kVersion},
            {"servers", sv},
            {"current", currentId},
            {"baseUrl", s ? s->url : ""},
            {"path", path},
            {"query", query},
            {"loading", loading},
            {"error", listError},
            {"entries", entries},
            {"perms", perms},
            {"transfers", tr},
            {"previews", pv},
            {"previewCache", !viewDir.empty()},
            {"downloadsDir", QStandardPaths::writableLocation(QStandardPaths::DownloadLocation).toStdString()},
            {"notice", notice},
            {"noticeKind", noticeKind},
            {"noticeAt", noticeAt},
        };
    }

    // ── listing
    void list()
    {
        Server* s = current();
        if (listReply) { listReply->abort(); listReply = nullptr; }
        entries = json::array();
        listError.clear();
        if (!s) { loading = false; perms = json::object(); changed(); return; }
        loading = true;
        previews.clear();
        previewQueue.clear();
        const quint64 gen = ++listGen;
        QUrl u = urlFor(*s, path);
        QUrlQuery qq;
        if (!query.empty()) qq.addQueryItem("q", QString::fromStdString(query));
        qq.addQueryItem("json", "");
        u.setQuery(qq);
        QNetworkReply* r = watch(net()->get(request(*s, u, 15000)));
        listReply = r;
        const std::string sid = s->id;
        QObject::connect(r, &QNetworkReply::finished, guarded("list", [this, r, gen, sid] {
            r->deleteLater();
            if (gen != listGen) return;
            listReply = nullptr;
            loading = false;
            if (r->error() != QNetworkReply::NoError) {
                listError = httpError(r);
                perms = json::object();
                changed();
                return;
            }
            json j = json::parse(r->readAll().toStdString(), nullptr, false);
            auto pathsIt = j.is_object() ? j.find("paths") : j.end();
            if (!j.is_object() || pathsIt == j.end() || !pathsIt->is_array()) {
                listError = "That address answered, but not like a dufs server (no JSON listing).";
                perms = json::object();
                changed();
                return;
            }
            if (!jbool(j, "dir_exists", true) && query.empty()) {
                listError = "This folder does not exist on the server (any more).";
                changed();
                return;
            }
            perms = {{"upload", jbool(j, "allow_upload", false)}, {"delete", jbool(j, "allow_delete", false)},
                     {"search", jbool(j, "allow_search", false)}, {"archive", jbool(j, "allow_archive", false)}};
            Server* sv = find(sid);
            std::vector<json> dirs, files;
            for (auto& p : *pathsIt) {
                if (!p.is_object()) continue;
                const std::string type = jstr(p, "path_type", "File");
                const bool dir = type.find("Dir") != std::string::npos;
                const std::string name = jstr(p, "name", "");
                if (name.empty() || name.find('\0') != std::string::npos) continue;
                // In search results dufs gives the path relative to the searched folder.
                std::string full = path + name;
                if (dir) full = normDir(full);
                json e = {{"name", baseName(full)}, {"rel", name}, {"path", full}, {"dir", dir}, {"kind", kindOf(name, dir)},
                          {"size", jnum(p, "size", 0)}, {"mtime", jnum(p, "mtime", 0)},
                          {"url", sv ? publicUrl(*sv, full) : ""}};
                (dir ? dirs : files).push_back(e);
            }
            auto byName = [](const json& a, const json& b) {
                return lower(a["name"].get<std::string>()) < lower(b["name"].get<std::string>());
            };
            std::sort(dirs.begin(), dirs.end(), byName);
            std::sort(files.begin(), files.end(), byName);
            for (auto& e : dirs) entries.push_back(e);
            for (auto& e : files) entries.push_back(e);
            changed();
        }));
    }

    void simpleOp(const QByteArray& verb, const std::string& target, const std::string& destination,
                  const std::string& okMsg)
    {
        Server* s = current();
        if (!s) return;
        QNetworkRequest req = request(*s, urlFor(*s, target), 30000);
        if (!destination.empty()) {
            req.setRawHeader("Destination", urlFor(*s, destination).toString(QUrl::FullyEncoded).toUtf8());
            req.setRawHeader("Overwrite", "F");
        }
        QNetworkReply* r = watch(net()->sendCustomRequest(req, verb));
        QObject::connect(r, &QNetworkReply::finished, guarded("op", [this, r, okMsg] {
            r->deleteLater();
            if (r->error() != QNetworkReply::NoError) note(httpError(r), "error");
            else note(okMsg, "ok");
            list();
        }));
    }

    // ── transfers
    Transfer* transfer(const std::string& id)
    {
        for (auto& t : transfers) if (t.id == id) return &t;
        return nullptr;
    }
    static std::string newId() { return QUuid::createUuid().toString(QUuid::Id128).left(12).toStdString(); }

    void pumpUploads()
    {
        int running = 0;
        for (auto& t : transfers) if (t.kind == "upload" && t.state == "running") running++;
        for (auto& t : transfers) {
            if (running >= kMaxUploadJobs) break;
            if (t.kind != "upload" || t.state != "queued") continue;
            startUpload(t);
            running++;
        }
    }

    void finishTransfer(const std::string& id, QNetworkReply* r, bool refreshIfHere)
    {
        Transfer* t = transfer(id);
        if (!t) return;
        if (t->file) { t->file->close(); delete t->file; t->file = nullptr; }
        const bool cancelled = t->state == "cancelled";
        const bool failed = !cancelled && r->error() != QNetworkReply::NoError;
        std::error_code ec;
        if (t->kind == "download" && (cancelled || failed)) fs::remove(t->local + ".part", ec);
        if (t->kind == "download" && !cancelled && !failed) {
            fs::rename(t->local + ".part", t->local, ec);
            if (ec) { t->state = "failed"; t->error = "Downloaded, but could not save to " + t->local + "."; fs::remove(t->local + ".part", ec); }
        }
        if (cancelled || t->state == "failed") {
            // already final
        } else if (failed) {
            t->state = "failed";
            t->error = httpError(r);
        } else {
            t->state = "done";
            if (t->total > 0) t->done = t->total;
            else t->total = t->done;
        }
        t->reply = nullptr;
        const std::string tdir = t->dir, tsid = t->serverId;
        if (refreshIfHere && tsid == currentId && tdir == path && query.empty()) list();
        pumpUploads();
        changed();
    }

    void startUpload(Transfer& t)
    {
        Server* s = find(t.serverId);
        if (!s) { t.state = "failed"; t.error = "The server was removed."; return; }
        auto* f = new QFile(QString::fromStdString(t.local));
        if (!f->open(QIODevice::ReadOnly)) {
            t.state = "failed"; t.error = "Cannot read the local file."; delete f; return;
        }
        t.file = f;
        t.total = f->size();
        t.state = "running";
        QNetworkRequest req = request(*s, urlFor(*s, t.path), 120000);
        req.setHeader(QNetworkRequest::ContentLengthHeader, t.total);
        req.setHeader(QNetworkRequest::ContentTypeHeader, "application/octet-stream");
        QNetworkReply* r = watch(net()->put(req, f));
        t.reply = r;
        const std::string id = t.id;
        QObject::connect(r, &QNetworkReply::uploadProgress, guarded("upload progress", [this, id](qint64 sent, qint64 total) {
            if (Transfer* x = transfer(id)) { x->done = sent; if (total > 0) x->total = total; changed(); }
        }));
        QObject::connect(r, &QNetworkReply::finished, guarded("upload", [this, id, r] { r->deleteLater(); finishTransfer(id, r, true); }));
    }

    void startDownload(Transfer& t, bool zip)
    {
        Server* s = find(t.serverId);
        if (!s) { t.state = "failed"; t.error = "The server was removed."; return; }
        std::error_code ec; fs::create_directories(fs::path(t.local).parent_path(), ec);
        // Write next to the target and rename on success, so a failed or cancelled download never
        // destroys a file the user chose to replace.
        auto* f = new QFile(QString::fromStdString(t.local + ".part"));
        if (!f->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            t.state = "failed"; t.error = "Cannot write to " + t.local + "."; delete f; return;
        }
        t.file = f;
        t.state = "running";
        QUrl u = urlFor(*s, t.path);
        if (zip) u.setQuery("zip");
        QNetworkReply* r = watch(net()->get(request(*s, u, 120000)));
        t.reply = r;
        const std::string id = t.id;
        QObject::connect(r, &QNetworkReply::readyRead, guarded("download read", [this, id, r] {
            Transfer* x = transfer(id);
            if (!x || !x->file) return;
            if (r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() >= 400) return;
            x->file->write(r->readAll());
        }));
        QObject::connect(r, &QNetworkReply::downloadProgress, guarded("download progress", [this, id](qint64 got, qint64 total) {
            if (Transfer* x = transfer(id)) { x->done = got; if (total > 0) x->total = total; changed(); }
        }));
        QObject::connect(r, &QNetworkReply::finished, guarded("download", [this, id, r] { r->deleteLater(); finishTransfer(id, r, false); }));
    }

    // ── previews
    std::string cacheDir() const { return viewDir.empty() ? "" : viewDir + "/cache"; }
    static std::string cachePrefix(const Server& s)
    {
        return QCryptographicHash::hash(QByteArray::fromStdString(s.id), QCryptographicHash::Sha1).toHex().left(10).toStdString() + "-";
    }
    void purgeCache(const Server& s)
    {
        const std::string dir = cacheDir();
        if (dir.empty()) return;
        const std::string pre = cachePrefix(s);
        std::error_code ec;
        for (auto& e : fs::directory_iterator(dir, ec))
            if (e.path().filename().string().rfind(pre, 0) == 0) fs::remove(e.path(), ec);
    }
    // A NUL byte, or many invalid UTF-8 sequences, in the first 4 KiB means "not text".
    static bool looksBinary(const QByteArray& b)
    {
        const QByteArray head = b.left(4096);
        if (head.contains('\0')) return true;
        const QString t = QString::fromUtf8(head);
        int bad = 0;
        for (QChar c : t) if (c == QChar::ReplacementCharacter) bad++;
        return t.size() > 0 && bad * 20 > t.size();
    }

    void pruneCache()
    {
        const std::string dir = cacheDir();
        if (dir.empty()) return;
        std::error_code ec;
        std::vector<std::pair<fs::file_time_type, fs::path>> files;
        qint64 total = 0;
        for (auto& e : fs::directory_iterator(dir, ec)) {
            if (!e.is_regular_file(ec)) continue;
            total += (qint64)e.file_size(ec);
            files.push_back({e.last_write_time(ec), e.path()});
        }
        if (total <= kCacheLimit) return;
        std::sort(files.begin(), files.end());
        for (auto& [t, p] : files) {
            if (total <= kCacheLimit * 3 / 4) break;
            total -= (qint64)fs::file_size(p, ec);
            fs::remove(p, ec);
        }
    }

    const json* entryFor(const std::string& p) const
    {
        for (auto& e : entries) if (jstr(e, "path", "") == p) return &e;
        return nullptr;
    }

    void pumpPreviews()
    {
        while (previewJobs < kMaxPreviewJobs && !previewQueue.empty()) {
            std::string p = previewQueue.front();
            previewQueue.pop_front();
            startPreview(p);
        }
    }

    void startPreview(const std::string& p)
    {
        Server* s = current();
        const json* e = entryFor(p);
        auto& pv = previews[p];
        if (!s || !e) { pv.state = "error"; pv.error = "Not in this folder any more."; return; }
        const std::string kind = jstr(*e, "kind", "");
        const quint64 gen = listGen;
        previewJobs++;
        if (kind == "image") {
            const std::string key = QCryptographicHash::hash(
                QByteArray::fromStdString(s->url + "|" + p + "|" + std::to_string(jnum(*e, "mtime", 0))),
                QCryptographicHash::Sha1).toHex().toStdString();
            const std::string ext = extOf(p);
            // Prefixed by the server, so removing a server can delete its cached previews.
            const std::string target = cacheDir() + "/" + cachePrefix(*s) + key + (ext.empty() ? "" : "." + ext);
            std::error_code ec;
            if (fs::exists(target, ec)) {
                previewJobs--;
                pv.state = "ready"; pv.file = target;
                return;
            }
            fs::create_directories(cacheDir(), ec);
            QNetworkReply* r = watch(net()->get(request(*s, urlFor(*s, p), 60000)));
            QObject::connect(r, &QNetworkReply::finished, guarded("image preview", [this, r, p, target, gen] {
                r->deleteLater();
                previewJobs--;
                if (gen == listGen) {
                    auto& x = previews[p];
                    if (r->error() != QNetworkReply::NoError) { x.state = "error"; x.error = httpError(r); }
                    else {
                        QFile f(QString::fromStdString(target + ".part"));
                        if (f.open(QIODevice::WriteOnly)) {
                            f.write(r->readAll()); f.close();
                            std::error_code ec2; fs::rename(target + ".part", target, ec2);
                            if (ec2) { x.state = "error"; x.error = "Cannot write the preview cache."; }
                            else { x.state = "ready"; x.file = target; }
                        } else { x.state = "error"; x.error = "Cannot write the preview cache (" + cacheDir() + ")."; }
                    }
                    changed();
                }
                pumpPreviews();
                pruneCache();
            }));
        } else {
            QNetworkRequest req = request(*s, urlFor(*s, p), 30000);
            // dufs answers 416 when the range runs past the end, so only ask for a range on big files.
            if (jnum(*e, "size", 0) > kTextPreviewBytes)
                req.setRawHeader("Range", "bytes=0-" + QByteArray::number(kTextPreviewBytes - 1));
            QNetworkReply* r = watch(net()->get(req));
            auto buf = std::make_shared<QByteArray>();
            QObject::connect(r, &QNetworkReply::readyRead, guarded("text preview read", [r, buf] {
                buf->append(r->readAll());
                if (buf->size() >= kTextPreviewBytes) r->abort();
            }));
            const qint64 size = jnum(*e, "size", 0);
            QObject::connect(r, &QNetworkReply::finished, guarded("text preview", [this, r, p, buf, gen, size] {
                r->deleteLater();
                previewJobs--;
                if (gen == listGen) {
                    auto& x = previews[p];
                    buf->append(r->readAll());
                    const bool cut = buf->size() >= kTextPreviewBytes;
                    if (r->error() != QNetworkReply::NoError && !cut) { x.state = "error"; x.error = httpError(r); }
                    else {
                        QByteArray b = buf->left(kTextPreviewBytes);
                        if (looksBinary(b)) { x.state = "error"; x.error = "This looks like a binary file, so there is no text preview."; }
                        else {
                            x.text = QString::fromUtf8(b).toStdString();
                            x.truncated = cut || size > kTextPreviewBytes;
                            x.state = "ready";
                        }
                    }
                    changed();
                }
                pumpPreviews();
            }));
        }
    }
};

// ── module API ──────────────────────────────────────────────────────────────

DufsCoreImpl::DufsCoreImpl() : d(new DufsCorePrivate(this))
{
    // A damaged servers.json must never stop the module from loading.
    try { d->load(); }
    catch (const std::exception& e) { std::fprintf(stderr, "[dufs_core] load: %s\n", e.what()); d->servers.clear(); d->currentId.clear(); }
}

DufsCoreImpl::~DufsCoreImpl()
{
    delete d->nam;
    delete d;
}

void DufsCoreImpl::onContextReady()
{
    // No calls to other modules here (Basecamp 0.3 rejects them); just the first listing.
    QTimer::singleShot(0, guarded("first listing", [this] { d->list(); }));
}

std::string DufsCoreImpl::snapshot()
{
    return d->state().dump();
}

std::string DufsCoreImpl::setViewDir(const std::string& dir)
{
    std::string p = localPathFrom(dir);
    while (p.size() > 1 && p.back() == '/') p.pop_back();
    d->viewDir = p;
    std::error_code ec;
    fs::create_directories(d->cacheDir(), ec);
    d->pruneCache();
    return d->state().dump();
}

std::string DufsCoreImpl::addServer(const std::string& name, const std::string& url, const std::string& user,
                                    const std::string& password)
{
    if (url.empty()) return json({{"ok", false}, {"error", "Enter the server address, like http://pi5.lan:5000"}}).dump();
    Server s;
    s.id = DufsCorePrivate::newId();
    s.url = DufsCorePrivate::normUrl(url);
    QUrl u(QString::fromStdString(s.url));
    if (!u.isValid() || u.host().isEmpty())
        return json({{"ok", false}, {"error", "That does not look like a server address."}}).dump();
    s.name = name.empty() ? u.host().toStdString() : name;
    s.user = user;
    s.password = password;
    d->servers.push_back(s);
    d->currentId = s.id;
    d->path = "/";
    d->query.clear();
    d->save();
    d->note("Added " + s.name, "ok");
    d->list();
    return d->state().dump();
}

std::string DufsCoreImpl::editServer(const std::string& id, const std::string& configJson)
{
    Server* s = d->find(id);
    if (!s) return json({{"ok", false}, {"error", "No such server."}}).dump();
    json c = json::parse(configJson, nullptr, false);
    if (!c.is_object()) return json({{"ok", false}, {"error", "Bad server settings."}}).dump();
    if (c.contains("name") && c["name"].is_string() && !c["name"].get<std::string>().empty()) s->name = c["name"];
    if (c.contains("url") && c["url"].is_string() && !c["url"].get<std::string>().empty()) {
        s->url = DufsCorePrivate::normUrl(c["url"]);
        s->lastPath = "/";
        if (id == d->currentId) d->path = "/";
    }
    if (c.contains("user") && c["user"].is_string()) s->user = c["user"];
    if (c.contains("password") && c["password"].is_string()) s->password = c["password"];
    d->save();
    d->note("Saved " + s->name, "ok");
    if (id == d->currentId) d->list();
    return d->state().dump();
}

std::string DufsCoreImpl::removeServer(const std::string& id)
{
    if (Server* gone = d->find(id)) d->purgeCache(*gone);
    auto& v = d->servers;
    const auto before = v.size();
    v.erase(std::remove_if(v.begin(), v.end(), [&](const Server& s) { return s.id == id; }), v.end());
    if (v.size() == before) return json({{"ok", false}, {"error", "No such server."}}).dump();
    if (d->currentId == id) {
        d->currentId = v.empty() ? "" : v.front().id;
        d->path = v.empty() ? "/" : normDir(v.front().lastPath);
        d->query.clear();
        d->list();
    }
    d->save();
    return d->state().dump();
}

std::string DufsCoreImpl::selectServer(const std::string& id)
{
    Server* s = d->find(id);
    if (!s) return json({{"ok", false}, {"error", "No such server."}}).dump();
    d->currentId = id;
    d->path = normDir(s->lastPath);
    d->query.clear();
    d->save();
    d->list();
    return d->state().dump();
}

std::string DufsCoreImpl::openDir(const std::string& path)
{
    d->path = normDir(path);
    d->query.clear();
    if (Server* s = d->current()) { s->lastPath = d->path; d->save(); }
    d->list();
    return d->state().dump();
}

std::string DufsCoreImpl::refresh()
{
    d->list();
    return d->state().dump();
}

std::string DufsCoreImpl::search(const std::string& query)
{
    d->query = query;
    d->list();
    return d->state().dump();
}

std::string DufsCoreImpl::makeDir(const std::string& name)
{
    if (!d->current()) return json({{"ok", false}, {"error", "Add a server first."}}).dump();
    if (name.empty() || name.find('/') != std::string::npos)
        return json({{"ok", false}, {"error", "Folder names cannot be empty or contain /."}}).dump();
    d->simpleOp("MKCOL", d->path + name, "", "Created " + name);
    return d->state().dump();
}

std::string DufsCoreImpl::removePath(const std::string& path)
{
    if (!d->current()) return json({{"ok", false}, {"error", "Add a server first."}}).dump();
    if (path.empty() || path == "/") return json({{"ok", false}, {"error", "Refusing to delete the server root."}}).dump();
    d->simpleOp("DELETE", path, "", "Deleted " + baseName(path));
    return d->state().dump();
}

std::string DufsCoreImpl::renamePath(const std::string& path, const std::string& newName)
{
    if (!d->current()) return json({{"ok", false}, {"error", "Add a server first."}}).dump();
    if (newName.empty() || newName.find('/') != std::string::npos)
        return json({{"ok", false}, {"error", "Names cannot be empty or contain /."}}).dump();
    const bool dir = !path.empty() && path.back() == '/';
    std::string dest = parentOf(path) + newName + (dir ? "/" : "");
    d->simpleOp("MOVE", path, dest, "Renamed to " + newName);
    return d->state().dump();
}

std::string DufsCoreImpl::upload(const std::string& localPathsJson)
{
    Server* s = d->current();
    if (!s) return json({{"ok", false}, {"error", "Add a server first."}}).dump();
    json list = json::parse(localPathsJson, nullptr, false);
    if (list.is_string()) list = json::array({list});
    if (!list.is_array()) return json({{"ok", false}, {"error", "Nothing to upload."}}).dump();
    int added = 0;
    std::string skipped;
    for (auto& item : list) {
        if (!item.is_string()) continue;
        const std::string local = localPathFrom(item.get<std::string>());
        QFileInfo fi(QString::fromStdString(local));
        if (!fi.isFile()) { skipped = fi.fileName().toStdString(); continue; }
        Transfer t;
        t.id = DufsCorePrivate::newId();
        t.kind = "upload";
        t.name = fi.fileName().toStdString();
        t.local = local;
        t.serverId = s->id;
        t.dir = d->path;
        t.path = d->path + t.name;
        t.total = fi.size();
        d->transfers.push_back(t);
        added++;
    }
    if (!skipped.empty()) d->note("Folders are not uploaded yet (skipped " + skipped + ").", "error");
    if (!added && skipped.empty()) return json({{"ok", false}, {"error", "Nothing to upload."}}).dump();
    d->pumpUploads();
    d->changed();
    return d->state().dump();
}

std::string DufsCoreImpl::download(const std::string& path, const std::string& localPath)
{
    Server* s = d->current();
    if (!s) return json({{"ok", false}, {"error", "Add a server first."}}).dump();
    const std::string local = localPathFrom(localPath);
    if (local.empty()) return json({{"ok", false}, {"error", "Choose where to save it."}}).dump();
    const bool dir = !path.empty() && path.back() == '/';
    Transfer t;
    t.id = DufsCorePrivate::newId();
    t.kind = "download";
    t.name = baseName(path) + (dir ? ".zip" : "");
    t.path = path;
    t.local = local;
    t.serverId = s->id;
    d->transfers.push_back(t);
    d->startDownload(d->transfers.back(), dir);
    d->changed();
    return d->state().dump();
}

std::string DufsCoreImpl::cancelTransfer(const std::string& id)
{
    Transfer* t = d->transfer(id);
    if (!t) return json({{"ok", false}, {"error", "No such transfer."}}).dump();
    if (t->state == "queued") t->state = "cancelled";
    else if (t->state == "running") { t->state = "cancelled"; if (t->reply) t->reply->abort(); }
    d->changed();
    return d->state().dump();
}

std::string DufsCoreImpl::clearTransfers()
{
    auto& v = d->transfers;
    v.erase(std::remove_if(v.begin(), v.end(), [](const Transfer& t) {
        return t.state == "done" || t.state == "failed" || t.state == "cancelled";
    }), v.end());
    return d->state().dump();
}

std::string DufsCoreImpl::preview(const std::string& path)
{
    const json* e = d->entryFor(path);
    if (!e) return json({{"ok", false}, {"error", "Not in this folder."}}).dump();
    const std::string kind = e->value("kind", "");
    auto it = d->previews.find(path);
    if (it != d->previews.end() && it->second.state != "error") return d->state().dump();
    auto& pv = d->previews[path];
    pv = Preview();
    if (kind == "image") {
        if (d->viewDir.empty()) { pv.state = "error"; pv.error = "The view did not register its cache folder."; }
        else if (e->value("size", (int64_t)0) > kMaxImagePreview) { pv.state = "error"; pv.error = "Too large to preview."; }
        else pv.state = "loading";
    } else if (kind == "text") {
        pv.state = "loading";
    } else {
        pv.state = "error"; pv.error = "No preview for this kind of file.";
    }
    if (pv.state == "loading") { d->previewQueue.push_back(path); d->pumpPreviews(); }
    d->changed();
    return d->state().dump();
}
