# Dufs for Logos Basecamp

Browse, preview, upload and download files on your [dufs](https://github.com/sigoden/dufs) servers from Logos Basecamp (0.3.x). Add as many servers as you like (a Pi at home, a box in the office) and switch between them in the sidebar.

- **Browse** folders as a list (sortable by name, size, date) or as a grid with image thumbnails
- **Preview** images and text files (first 64 KB) in a side panel; double-click an image for full size
- **Markdown** files preview rendered (headings, lists, tables, code, links that open in the browser), or as source
- **HTML** files preview in a real browser engine when Basecamp provides Qt WebView (Linux, macOS): JavaScript off, and a Content-Security-Policy lets the page load only from its own dufs server, so no external scripts, styles, fonts, images, frames or trackers; a clicked link opens in your browser. Without WebView, a rich-text preview (Qt's CSS subset, no layout). Or as source.
- **Resize** the server list and the preview panel by dragging their edges; double-click an edge for the default width
- **Upload** by dropping files onto the window, or with the Upload button; progress shows at the bottom
- **Download** files, or whole folders as a `.zip`
- **New folder, rename, delete, search** (Ctrl+F; the ✕ or Esc clears it), copy a file's link, open it in the browser
- **Links into Dufs**: "Copy Basecamp link" gives `basecamp://intent/dufs.open?p=…`, which opens that file (or folder) in Dufs from another app, a note or a browser. Other apps can also ask for it directly with the `dufs.open` intent, `{ "url": "http://pi5.lan:5000/docs/notes.md" }`; the server must be one you added to Dufs. To open one by hand, press **Go to…** (or Ctrl+L) and paste a file's address or a Basecamp link.
- **Pinned and Recent**: pin a file or folder from its menu, the preview panel, or the ☆ in the toolbar (the folder you are in); they stay in the sidebar under the servers. Files you open show up under Recent (the last 12). Both are kept per server, in the same file as the server list.
- **Logins**: servers started with `--auth` take a user name and password
- **Logos Storage**: "Logos Storage" sits in the server list and browses like a server: the same list and grid, search, previews of images, text and markdown in the side panel, upload (or drop files), download, delete and pin. Each file shows where it came from and its CID ("Copy CID"). A file on a dufs server goes there with "To Logos Storage"; a file in Storage goes to a server with "To a dufs server…"; "Add by CID" fetches one someone shared. Storage has no folders, and a file can't be renamed (its name is part of its CID). ⋯ beside it picks the node (this computer's, or one elsewhere) and whether to announce.

What a server allows depends on how dufs runs: `dufs -A /data` allows everything (upload, delete, search, archive); without the `--allow-*` flags the buttons are disabled and the view says why.

## Packages

| Package | Type | What it does |
|---|---|---|
| `dufs_core` | core (universal) | All HTTP to the servers (Qt Network), the server list, transfers, preview cache, and Logos Storage (depends on `storage_module` and `storage_gateway`) |
| `dufs` | ui_qml | The view. Pure QML; renders `dufs_core.snapshot()` |

Basecamp 0.3 sandboxes views: no network, and no local files outside the view's own install dir. So every request runs in `dufs_core`, and image previews are written to `<view install dir>/cache/` (capped at 400 MB, oldest pruned), the one place the view can load an image from.

### Logos Storage

`dufs_core` uses the Storage node Basecamp 0.3 runs for every app (`storage_module`; the host starts it on the public `logos.test` network and Dufs never stops or reconfigures it). What the node holds comes from its own list of manifests; Dufs adds where each file came from (`~/.dufs-basecamp/storage.json`). Copies between a dufs server and Storage go through a temporary file in `~/.dufs-basecamp/storage-tmp/`, removed when the copy ends.

Content in Storage is addressed by CID, and with "Announce" on (the default) anyone who has a file's CID can fetch it from this computer while it is online and reachable. Keep private files on your dufs servers. Fetching from someone else needs their node to be reachable: two computers behind home routers often can't reach each other, and Storage has no relay fleet like Logos Messaging. storage_module 3.0.3 (on the same package repositories) carries a libstorage fix for downloads that ignored a holder that answered.

#### A Storage node elsewhere

"Node…" in the Storage pane switches from this computer's node to one on a server, for example
an always-on VPS with a public address that serves your files to the network while your laptop
sleeps. Dufs then talks to that node through
[`storage_gateway`](https://github.com/vpavlin/logos-storage-gateway). It has the same API as
`storage_module`, so the code is the same and only the module differs. Its job is to reach the
node's REST API (`logos-storage --api-bindaddr …`).

Files go from this computer to the node and back; dufs servers work as before. The REST API has
no password, so the address must only be reachable over your VPN or mesh (e.g.
`http://[fd…]:8480`), never a public one. The choice is kept in `storage.json` (`node`).

Downloads run with announcing off and are announced once whole, so a failed download never
leaves this node listed as a holder of data it doesn't have.

Servers are stored in `~/.dufs-basecamp/servers.json` (mode 600). Passwords are stored there in plain text, so only add logins on a machine you trust.

## Build

```sh
cd core && nix build .#lgx-portable    # dufs_core
cd ui   && nix build .#lgx-portable    # dufs (view)
```

Both use `logos-module-builder` 0.3.1. Published packages carry `linux-amd64` and `linux-arm64` (the ARM variant is built by `.github/workflows/platform-modules.yml` on `ubuntu-24.04-arm` and merged with `lgx merge`).

## Test

- **Headless core:** load `dufs_core` under `logosctl` and call it (`addServer`, `openDir`, `upload`, `preview`, `snapshot`, `storageRefresh`, `sendToStorage`, `saveToServer`, ...). logosctl starts its own Storage node, so two sessions (each with its own HOME) are two Storage nodes.
- **View render:** `ui/harness/render.sh "<qml steps>"` renders `Main.qml` offscreen with a `logos` bridge that forwards every call to that live core, and writes screenshots to `ui/harness/shots/`.

## Later

- Folders into Logos Storage (files only for now), and a shared list of CIDs across your devices.
- Folder uploads (dropping a folder is skipped for now, with a message).

## License

Dual-licensed under MIT ([LICENSE-MIT](LICENSE-MIT)) and Apache 2.0 ([LICENSE-APACHE](LICENSE-APACHE)).
