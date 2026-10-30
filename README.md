# Sushi Launcher 🍣💣

A native macOS (SwiftUI) front end for [`sushi`](https://github.com/beamivalice/sushi) —
the Zig-based, low-bit-quant LLM serving engine for Apple Silicon. It wraps
`sushi serve` with every affordance a Mac app is expected to have: a real
menu bar, keyboard shortcuts, a Settings window, a live console for the
server's stdout/stderr, a curated model browser with in-app downloads, and a
menu-bar resident mode so the model can outlive the window.

---

## Why this exists

`sushi` is a terminal program, and running it well from a terminal means
memorizing a launch ritual like this:

```sh
sudo sysctl iogpu.wired_limit_mb=120000      # resets at every reboot — must be redone
sushi serve \
  --model ~/.sushi/models/Qwen3.8-Flash-Next-Sushi-4bpw \
  --mtp --kv-quant 8 --mtp-head-kv-quant \
  --ctx-size 1048576 --prefill-chunk 2048 --max-tokens 64000 \
  --prefix-cache-disk 20GB --prefix-cache-entries 1 --temp 1
```

That is a *recipe*: which pack, which context, which quant, which cache
budget, matched to how much unified memory your Mac has — and getting one
number wrong means a refusal or a panic, thirty seconds into a large model
load, in a terminal window you closed anyway.

Sushi Launcher turns that ritual into: pick your Mac's recipe, pick your
model, press **Start**, watch it come up in the console, close the window,
and keep an eye on it from the menu bar. The knowledge that *should* live in
tooling — the launch recipes, the memory tables, which flags each model
family refuses, when to raise the GPU limit — is baked in. The terminal
escape hatch never goes away: every screen shows you the exact command line,
and **Copy Command Line** puts it on your pasteboard verbatim.

The name is earned twice over: it launches sushi, and the icon is the
Perfect Dark sushi cannon.

---

## What it does

### Guided launching
- **Launch recipes** (presets) grouped by machine class, each with a plain
  explanation: which Mac it fits, what it trades off, which
  `iogpu.wired_limit_mb` to raise first. The default recipe is the classic
  128 GB / Qwen 4bpw / full-1M-context launch; the docs' 48/64/96/128 GB
  recipes and the SSD-streamed DeepSeek launch ship alongside. Diverge from
  a preset and the picker honestly says *Custom configuration*.
- **Curated model picker** — a popover (not a `<select>`-style menu):
  recommended packs first, ruled off from the rest, filter box, per-row
  quant/size/estimated-residency sublines, and a detail pane with family
  notes, memory estimates, license, and **live parameter counts and
  download stats** fetched from the Hugging Face API. Packs you don't own
  get a one-click **Download** that streams `sushi pull` with progress and
  cancel; interrupted pulls resume by rerunning them.
- **GPU wired limit** — Server ▸ Raise GPU Memory Limit (⌥⌘G) runs the
  `sysctl` through the native macOS authorization prompt; an optional
  "before every launch" mode covers the resets-at-reboot reality.

### Full fidelity to the CLI
- Every shared `serve` flag from sushi's `docs/flags.md` (~55 options) is
  editable — behind an **Advanced flag editor** toggle so first-timers only
  see the handful that matter (Quick settings).
- Flags that a model family **refuses at load** (e.g. DeepSeek rejects
  `--kv-quant`) get a warning triangle the moment they'd bite you.
- Command preview mirrors exactly what will run, including the auto-appended
  `--parent-pid` watchdog (Settings ▸ Server can hand that job back to you).

### Live console
- Streaming stdout/stderr in a resizable bottom **drawer** (⇧⌘L), with a
  slim status strip when closed.
- **Content-based severity** (more below), per-subsystem colored chips
  (`[mtp]`, `[qsa]`, `[disk-cache]`, …) with stable colors across launches,
  Issues filter, text filter, timestamps, autoscroll, copy/save that agree
  with what the screen shows.

### Menu-bar resident mode
- A template glyph (auto-derived from the bundled artwork) with a dropdown
  showing server state, uptime, pid, model, URL, log volume — plus
  start/stop/restart and one-click window restore.
- Closing the last window can hide the Dock icon entirely (app flips to
  `.accessory`): sushi keeps serving, the menu bar is the interface,
  and everything finds its way back.

---

## How it works

```
Package.swift                    SwiftPM executable target
build-app.sh                     build → assemble → strip xattrs → sign (ad-hoc, or NOTARIZE=1)
Resources/Info.plist             bundle metadata
Sources/SushiLauncher/
  App/       entry point, scenes, menu commands, AppModel, NSStatusItem controller
  Engine/    ServerController, ModelCatalog, PackEnricher, SushiRunner
  Model/     SushiOption registry, LaunchConfig, Presets, ModelFamily, PackKnowledge
  Support/   Shell/GPULimit/Storage/UIActions, PendingLines buffer + log levels
  UI/        ContentView, LaunchPane, OptionRow, ModelPicker, LogView, ModelsView, SettingsView
icons/       app artwork (squircle for macOS 26+, plate-free for earlier)
```

### The flag registry — one row per option
`SushiOption.swift` is a table: id, kind (presence / on-off / int / double /
text / choice), category, default, help text, and refused-by families. The
form controls, the argument builder, the command preview, presets,
family warnings, and JSON persistence are *all derived from that table*.
Supporting sushi's next release flag means adding one row:

```swift
SushiOption(id: "new-trick", title: "New trick", category: .kv,
            kind: .double(0), help: "0…1 what it does. MiMo refuses.",
            unsupported: [.mimo]),
```

### Process pipeline
`ServerController` launches sushi with a PATH-hardened environment (Finder
gives apps almost nothing), drains stdout/stderr through pipe
readability-handlers into a lock-guarded line reassembler
(`PendingLines`), and flushes into a 20k-line ring buffer at ~5 Hz so the UI
stays smooth under token storms. Readiness is a race: the banner
(`Server listening on http://…` / any `listening` match) versus an HTTP poll
of `/v1/models` — whichever confirms first flips *Starting → Serving*. Stop
is SIGTERM with a 7 s SIGKILL escalation; the `--parent-pid` watchdog means
a killed launcher never orphans an 87 GiB serving model.

### Log severity by content, not pipe
sushi logs *everything* to stderr, so a stream-based color scheme is just
noise with extra steps. `detectLogLevel()` classifies each line: Zig-style
`err:`/`warn:` prefixes, then a deliberately small set of failure phrases
(`already in use`, `refus`, `panic`, `out of memory`…), with periodic stats
(`[spec-stats]`, `RSS:`… lines) demoted to debug. Info is the default;
scary should mean scary. Badges — on screen and in Copy/Save — read
`INF/WRN/ERR/DBG/APP` from that classification.

### Models: list, match, enrich
`ModelCatalog` parses the fixed-width `sushi list` table (tolerantly — the
raw output is kept as fallback) and owns the `sushi pull` child process.
`SushiPack.match` reconciles what `--model` holds (short name *or* folder
path) back to a catalog row by comparing punctuation-folded,
"sushi"-stripped names. Memory figures the CLI doesn't expose come from
`PackKnowledge`: documented per-family anchors (weights-only and 1M-context
GiB) with interpolation for new quants, marked `≈`; parameters and download
stats come live from the Hugging Face model API with an exact repo table
plus a naming heuristic, degrading silently offline.

### Persistence
`~/Library/Application Support/SushiLauncher/launch-config.json` and
`settings.json`, debounced 400 ms after changes, decoded with
`decodeIfPresent` fallbacks so older files keep loading when fields are
added. The menu-bar visibility flag lives in `UserDefaults` instead — see
below for why that one matters.

### SwiftUI / AppKit boundary (a.k.a. things we learned the hard way)
- The status item is a hand-rolled **`NSStatusItem`**, not `MenuBarExtra`:
  MenuBarExtra renders labels as alpha templates (opaque artwork is
  invisible) and its `isInserted` plumbing was implicated in a launch-time
  scene-list recursion (stack overflow). The glyph itself is generated at
  runtime: pixel coverage = `alpha − mean(premultiplied RGB)`, which turns
  black-on-white, black-on-transparent, *and* colored artwork into a proper
  template that tints for the menu bar's appearance.
- The main window is a single-instance **`Window` scene**, not a
  `WindowGroup`: closing a WindowGroup destroys the window, and with no
  windows there is no SwiftUI surface left to resurrect one. A `Window`
  survives closure hidden, so the menu bar can always bring it back;
  `openWindow(id:)`-only targets (like Models before its first open) are
  driven through notifications that any live SwiftUI surface services.
- Menu content are little `View`s observing the controllers directly, so
  Start/Stop/Restart enable and disable themselves live.
- Bundled artwork ships in both eras: the plate-free 832 icon as the bundle
  `AppIcon.icns` (macOS < 26 rounds it itself), and on macOS 26+ the app
  swaps `NSApp.applicationIconImage` to the pre-rendered squircle — one
  build for both.

---

## Build & run

Requirements: macOS 14+, Xcode command-line tools, and sushi
(`brew install beamivalice/tap/sushi`, or point Settings ▸ sushi binary at
your own build).

```zsh
./build-app.sh
open 'build/Sushi Launcher.app'
# or install it properly:
rm -rf '/Applications/Sushi Launcher.app'
cp -R 'build/Sushi Launcher.app' /Applications/
```

The script compiles release, assembles the bundle, copies the icons (menu
glyph: `icons/sushi-menuTemplate.png` ▸ `~/Desktop/sushi-launcher.png` ▸
`icons/sushi-launcher-plain.png`), strips Finder xattrs (`xattr -cr` —
detritus makes codesign fail), and signs. The app is **unsandboxed
by design**: it must exec sushi, bind a port, and read `~/.sushi`. Ad-hoc
signing (the default) is everything your own machine needs — locally built
files never get quarantined. To hand the app to *other* Macs, build with
`NOTARIZE=1`: it switches to a Developer ID certificate + hardened runtime,
submits to Apple's notary service, and staples the ticket so Gatekeeper
opens it happily. One-time setup (identity in Keychain + `xcrun
notarytool store-credentials`) is documented in the step-4 comment of
`build-app.sh`.

## Keyboard shortcuts

| Key | Action | | Key | Action |
|---|---|---|---|---|
| ⌘S | Start server | | ⌘⇧M | Models… |
| ⌘. | Stop server | | ⌘⇧L | Console drawer |
| ⌘R | Restart server | | ⌥⌘F | Advanced flag editor |
| ⌘⇧C | Copy command line | | ⌥⌘G | Raise GPU limit |
| ⌘⇧O | Open server URL | | ⌘0 | Open window (from menu bar) |
| ⌘, | Settings | | ⌘⌥A | Autoscroll |

## Troubleshooting

- **"port 12345 is already in use"** — another sushi is serving. Stop it,
  or change the port in Quick settings.
- **sushi not found** — install the tap or set the path in Settings; the
  console prints the resolved command line on every launch attempt.
- **Model fails to load naming a flag** — that family refuses it (watch for
  the red triangle); uncheck the flag or pick a different recipe.
- **Nothing in the menu bar** — check Settings ▸ Menu bar, and note that
  notched MacBooks crowd menu extras behind the notch; quit a few.
- **Stale copy in /Applications** — after rebuilding, reinstall; the old
  bundle can even fail to launch (signature invalid after in-place edits).
- **Settings won't migrate** — delete
  `~/Library/Application Support/SushiLauncher/` to start clean.

## Privacy & network

The app itself talks to the network in exactly two places: the Hugging Face
model API to enrich the picker (parameter counts, download stats), and sushi
itself when pulling packs / checking releases (suppress the latter with
`--no-update-check`). Launch flags you enter — including `--api-key` — are
passed to the child process as argv, visible in the process table and in
`ps` output; sushi's `--api-key-env` exists for keeping them out.

## Credits

- **sushi** — [beamivalice/sushi](https://github.com/beamivalice/sushi),
  Apache-2.0; a detached fork of mlx-serve. Docs (`flags.md`, `usage.md`,
  `server-lifecycle.md`) supplied nearly every fact baked into this app.
- **Icon** — the sushi cannon artwork from the sushi project, in squircle
  (macOS 26) and plate-free (legacy) editions.
- Pack knowledge table hand-assembled from sushi's memory matrix; send
  corrections (or wait for it to interpolate `≈`).

MIT — do with it as you wish, feed it well.
