# Dufs for Logos Basecamp

Browse, preview, upload and download files on your [dufs](https://github.com/sigoden/dufs) servers from Logos Basecamp (0.3.x). Add as many servers as you like (a Pi at home, a box in the office) and switch between them in the sidebar.

- **Browse** folders as a list (sortable by name, size, date) or as a grid with image thumbnails
- **Preview** images and text files (first 64 KB) in a side panel; double-click an image for full size
- **Upload** by dropping files onto the window, or with the Upload button; progress shows at the bottom
- **Download** files, or whole folders as a `.zip`
- **New folder, rename, delete, search**, copy a file's link, open it in the browser
- **Logins**: servers started with `--auth` take a user name and password

What a server allows depends on how dufs runs: `dufs -A /data` allows everything (upload, delete, search, archive); without the `--allow-*` flags the buttons are disabled and the view says why.

## Packages

| Package | Type | What it does |
|---|---|---|
| `dufs_core` | core (universal) | All HTTP to the servers (Qt Network), the server list, transfers, preview cache |
| `dufs` | ui_qml | The view. Pure QML; renders `dufs_core.snapshot()` |

Basecamp 0.3 sandboxes views: no network, and no local files outside the view's own install dir. So every request runs in `dufs_core`, and image previews are written to `<view install dir>/cache/` (capped at 400 MB, oldest pruned), the one place the view can load an image from.

Servers are stored in `~/.dufs-basecamp/servers.json` (mode 600). Passwords are stored there in plain text, so only add logins on a machine you trust.

## Build

```sh
cd core && nix build .#lgx-portable    # dufs_core
cd ui   && nix build .#lgx-portable    # dufs (view)
```

Both use `logos-module-builder` 0.3.1. Published packages carry `linux-amd64` and `linux-arm64` (the ARM variant is built by `.github/workflows/platform-modules.yml` on `ubuntu-24.04-arm` and merged with `lgx merge`).

## Test

- **Headless core:** load `dufs_core` under `logosctl` and call it (`addServer`, `openDir`, `upload`, `preview`, `snapshot`, ...).
- **View render:** `ui/harness/render.sh "<qml steps>"` renders `Main.qml` offscreen with a `logos` bridge that forwards every call to that live core, and writes screenshots to `ui/harness/shots/`.

## Later

- Push a file to Logos Storage and get a CID back.
- Folder uploads (dropping a folder is skipped for now, with a message).

## License

Dual-licensed under MIT ([LICENSE-MIT](LICENSE-MIT)) and Apache 2.0 ([LICENSE-APACHE](LICENSE-APACHE)).
