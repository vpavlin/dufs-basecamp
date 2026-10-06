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

    void onContextReady() override;

logos_events:
    // The same JSON snapshot() returns, pushed after every change.
    void stateChanged(const std::string& json);

private:
    DufsCorePrivate* d = nullptr;
    friend struct DufsCorePrivate;
};
