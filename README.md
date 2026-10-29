# Sushi Launcher 🍣💣

A native macOS SwiftUI front end for [`sushi`](https://github.com/beamivalice/sushi) —
the Zig-based low-bit LLM serving engine for Apple Silicon. It launches
`sushi serve`, exposes every shared serve flag through a data-driven
settings form, shows the live stdout/stderr in a console pane, and browses
model packs via `sushi list` / `sushi pull`.

## Build & run

Requires macOS 14+ with Xcode command-line tools. From this folder:

```zsh
./build-app.sh
open 'build/Sushi Launcher.app'
```

The script compiles a release build, assembles the `.app`, wires the icons
and ad-hoc signs it. Install to `~/Applications` if you like. (Optional:
`echo '.build/' > .gitignore && echo 'build/' >> .gitignore`.)

## What you get

- **Proper macOS citizen** — full menu bar (App / File / Server / View /
  Window / Help), Settings window (⌘,), About panel, Services, standard
  shortcuts, undo-style debounced persistence to
  `~/Library/Application Support/SushiLauncher/`.
- **Server menu** — Start ⌘S · Stop ⌘. · Restart ⌘R · Copy Command Line
  ⌘⇧C · Open Server URL ⌘⇧O · Raise GPU Memory Limit ⌥⌘G · sushi version.
- **Curated model selection** — the Model picker lists exactly the packs
  sushi can serve (via `sushi list`): ★ recommended for this Mac, ✓
  installed, size, and *fits* / *may stream* status. Selecting an installed
  pack sets it as `--model`; selecting a missing one offers a one-click
  **Download** that streams `sushi pull` right in the form (interrupted
  pulls resume — rerun Download). *Choose folder…* and the Models window
  remain for power paths.
- **Launch recipes with explanations** — presets are grouped (This machine
  / Reference recipes / 128 GB & streaming / Start over), each with a plain
  caption: which Mac it fits, what it trades, which `iogpu.wired_limit_mb`
  to raise first. Your start-sushi recipe is the default.
- **Beginner by default, deep on demand** — Quick settings always show; the
  full by-category flag editor (all 50+ options) opens behind
  View ▸ Advanced Flag Editor (⌥⌘F), which also reveals the raw `--model`
  row.
- **Console drawer** — the stdout/stderr console is a toggleable bottom
  drawer (⇧⌘L or the chevron in the status bar). When closed, a slim bar
  keeps the line count and server-lights visible.
- **Every serve flag, modularly** — one table in
  `Sources/SushiLauncher/Model/SushiOption.swift` defines each option
  (kind, category, default, help text, model-family refusals). The form,
  the argv builder, presets, the copyable command line and JSON persistence
  all derive from it. **Add a future sushi option = add one row.**
- **Presets** — your `start-sushi` recipe (Qwen 4bpw · 128 GB) is the
  default; the docs' 48/64/96/128 GB recipes and a streamed-DeepSeek recipe
  ship alongside. Apply replaces the whole config; the menu shows *Custom*
  once you diverge.
- **Live console** — color-coded OUT/ERR/APP streams, filter box,
  errors-only, autoscroll, timestamps, copy/save, 20 k-line ring buffer.
  Ready state is detected by matching sushi's
  `server: http://… (Press Ctrl+C to stop)` banner, raced against an HTTP
  probe of `/v1/models`.
- **Models window** (⌘⇧M) — parses `sushi list`: size, downloaded,
  *fits* / *may stream* / ★ recommended for this Mac, plus a **Pull** action
  with live output and **Use** to set the launch model.
- **GPU wired limit** — the `sudo sysctl iogpu.wired_limit_mb=…` step from
  your script is a menu command (native password/Touch ID prompt via
  `osascript … with administrator privileges`), optionally run before every
  launch. The limit resets at reboot, hence the "Check current" helper.
- **Watchdog** — `--parent-pid <launcher pid>` is appended automatically so
  a killed launcher never orphans a serving model (Settings ▸ Server to
  turn off).
- **Icon** — bundle icon is the plate-free `sushi-launcher-plain-832.icns`
  (correct on macOS < 26 where the OS rounds icons). On macOS 26+ the app
  swaps `NSApp.applicationIconImage` to `sushi-launcher-squircle.png` at
  runtime — one build serves both.

## Layout

```
Package.swift                 SwiftPM manifest (executable target)
build-app.sh                  build → bundle → sign
Resources/Info.plist          bundle metadata (CFBundleIconFile → AppIcon)
Sources/SushiLauncher/
  App/       entry point, scenes, menu commands, AppModel, icon swap
  Engine/    ServerController (process + log stream), ModelCatalog (list/pull)
  Model/     SushiOption registry, LaunchConfig, Presets, ModelFamily, packs
  Support/   Shell/GPULimit/Storage/UIActions, PendingLines buffer
  UI/        ContentView, LaunchPane, OptionRow, LogView, ModelsView, Settings
```

## Notes & troubleshooting

- **Port 12345 busy** — another sushi is running; the log pane says so.
  Change the port in Quick settings.
- **`sushi` not found** — install with `brew install beamivalice/tap/sushi`,
  or point Settings ▸ sushi binary at it (e.g. `~/.local/bin/sushi`).
- **Model path vs pack name** — `--model` accepts both a directory
  (`~/.sushi/models/…`) and a `sushi pull` short name
  (`qwen3.8-flash-next:4bpw`). The *Use* button sets the short name.
- **Flag warnings** — a red triangle marks flags the detected model family
  refuses at load (e.g. `--kv-quant` on DeepSeek-V4.1); sushi exits with an
  error naming them, so uncheck first.
- The app is unsandboxed by design (it must exec sushi, bind a port and
  read `~/.sushi`); it is ad-hoc signed. If you distribute it, sign with a
  Developer ID and notarize.
