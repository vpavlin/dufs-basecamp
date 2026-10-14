#pragma once

#include <string>
#include "logos_module_context.h"

struct DufsCorePrivate;

/**
 * DufsCoreImpl - the engine behind the Dufs Basecamp view.
 *
 * Talks to one or more dufs file servers (https://github.com/sigoden/dufs) over HTTP:
 * list a folder, search, upload local files, download, make folders, rename, delete,
 * and fetch previews. The view is sandboxed (no network, no files outside its own
 * install dir), so every request runs here and the view only renders snapshot().
 *
 * Rules the module glue imposes (see the logos-basecamp-module skill):
 *  - every public method returns a JSON string; mutations return the fresh snapshot
 *  - no default arguments, at most 4 arguments, no trailing comments on declarations
 *  - requests are asynchronous; progress and results arrive through snapshot() and
 *    the stateChanged event
 *
 * Logos Storage is a dependency (storage_module): its node lists the files it holds, takes files
 * from this computer or a dufs server, and gives them back to either.
 *
 * Servers (with an optional login) are kept in $HOME/.dufs-basecamp/servers.json
 * (override the directory with DUFS_CORE_DATA).
 */
class DufsCoreImpl : public LogosModuleContext
{
public:
    DufsCoreImpl();
    ~DufsCoreImpl() override;

    // Full state: servers, the current folder listing, transfers, previews.
    std::string snapshot();

    // The view's own directory. Image previews are cached under <dir>/cache, the
    // only place the sandboxed view may load a local file from.
    std::string setViewDir(const std::string& dir);

    // Servers. url like "http://pi5.lan:5000" (a sub-path is fine). user/password may be empty.
    std::string addServer(const std::string& name, const std::string& url, const std::string& user, const std::string& password);
    // configJson: {"name","url","user","password"}; a missing key keeps the old value.
    std::string editServer(const std::string& id, const std::string& configJson);
    std::string removeServer(const std::string& id);
    std::string selectServer(const std::string& id);

    // Browsing. Paths are absolute on the server, e.g. "/photos/2026/".
    std::string openDir(const std::string& path);
    std::string refresh();
    // Search below the current folder; an empty query goes back to the plain listing.
    std::string search(const std::string& query);

    // Changes in the current folder / on a path.
    std::string makeDir(const std::string& name);
    std::string removePath(const std::string& path);
    std::string renamePath(const std::string& path, const std::string& newName);

    // Transfers. localPathsJson: ["/home/me/a.jpg", "file:///home/me/b.png", ...] into the current folder.
    std::string upload(const std::string& localPathsJson);
    // A folder downloads as a .zip (when the server allows archives).
    std::string download(const std::string& path, const std::string& localPath);
    std::string cancelTransfer(const std::string& id);
    std::string clearTransfers();

    // Image: fetched into the view's cache dir. Text: the first 64 KiB inline.
    std::string preview(const std::string& path);

    // Places: pinned and recently opened files/folders ("/a/b.md", "/a/"), kept per server.
    std::string pinPath(const std::string& serverId, const std::string& path);
    std::string unpinPath(const std::string& serverId, const std::string& path);
    // Moves the path to the top of the recent list (at most 12 kept).
    std::string touchPath(const std::string& serverId, const std::string& path);
    // An empty serverId clears the whole recent list.
    std::string forgetRecent(const std::string& serverId, const std::string& path);

    // ── Logos Storage: this computer's node (on Basecamp 0.3, the host's), shown as one more place
    // beside the servers. Results arrive through snapshot().storage and the transfer list.

    // Starts using the node (once) and lists the files it holds.
    std::string storageRefresh();
    // localPathsJson as for upload(): the files go into Storage.
    std::string storageUpload(const std::string& localPathsJson);
    // A file in Storage, by its CID, to a file on this computer.
    std::string storageDownload(const std::string& cid, const std::string& localPath);
    // Fetches a CID someone shared, so this node holds it (and serves it, when announcing).
    std::string storageAdd(const std::string& cid);
    // Drops a file from this node.
    std::string storageRemove(const std::string& cid);
    // A file on a dufs server into Storage.
    std::string sendToStorage(const std::string& serverId, const std::string& path);
    // A file in Storage onto a dufs server, into dir ("/a/b/").
    std::string saveToServer(const std::string& cid, const std::string& serverId, const std::string& dir);
    // settingsJson: {"advertise": true} announces what is put into Storage, so others can fetch it by CID.
    std::string storageSettings(const std::string& settingsJson);

    // Opens an http(s) link in the system browser (the sandboxed view's Qt.openUrlExternally can't).
    std::string openUrl(const std::string& url);

    void onContextReady() override;

logos_events:
    // The same JSON snapshot() returns, pushed after every change.
    void stateChanged(const std::string& json);

private:
    DufsCorePrivate* d = nullptr;
    friend struct DufsCorePrivate;
};
