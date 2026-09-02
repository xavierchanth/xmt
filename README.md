# XMT — Xavier's macOS Tweaks

XMT is a personal macOS menu bar app that collects chosen macOS behavior changes into one user-visible app and UI, so there is one product to install, permission, configure, and remember instead of one per tweak. Safety-critical keyboard customization may eventually use isolated built-in helper and system-extension components; it is not a plugin model. This README covers what ships today and how to build, run, and test it; [the documentation tree](docs/README.md) covers product intent, architecture, and roadmap.

## What ships today

Two modules are built in.

**Window Mover** — a global shortcut (default **Option-Space**) that moves the focused window to the next display, wrapping around, preserving relative geometry, and handling native full-screen windows. Specified in [the Window Mover specification](docs/specification/window-mover.md).

**Voice Transcription** — hold **Fn** to dictate, or press **Fn-Space** to latch recording on and off. Speech is analyzed on device with macOS 26's `SpeechAnalyzer`, the transcript goes to the clipboard and optionally pastes itself into the focused input, and an interrupted recording is kept so it can be retried once. Specified in [the Voice Transcription specification](docs/specification/voice-transcription.md). It is implemented and integrated but **has not yet been validated against real microphone, Speech, or paste behavior**; see [validation gaps](docs/roadmap/README.md#voice-transcription-validation-gaps) before relying on it.

Supporting behavior:

- Lives in the menu bar as an `LSUIElement` app with no Dock icon.
- Rebindable global shortcut powered by [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts).
- Contextual permission status and request actions in Settings; launch does not prompt.
- An optional declarative config file at `~/.config/xmt/config.json`, specified in [the configuration specification](docs/specification/configuration.md).
- Launch at Login through `SMAppService`.

Keyboard Customization is **not implemented**; its approved direction is at a gated feasibility spike. Cross-app Menu Bar Management is a public-API no-go. See [the roadmap](docs/roadmap/README.md) and [module inventory](docs/architecture/modules.md#module-inventory).

## Status

Maintained for personal use. There are no plans to publish it and no support commitment.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- Accessibility permission for Window Mover, the consuming Voice Fn shortcut tap, clipboard-first paste or clipboard-only output, and Paste Latest
- Microphone and Input Monitoring permission for Voice Transcription
- Speech assets for the configured locale, downloadable from the Voice settings tab

## Installing

With [`just`](https://github.com/casey/just) installed, build a Release app and copy it to `/Applications`:

```bash
just install
```

That recipe quits a running copy, replaces `/Applications/XMT.app`, and launches the result. Open `Settings...` from the menu bar icon to configure each module and grant its permissions contextually.

To build and launch without installing:

```bash
just run
```

Both build into `.build/xcode`; `just clean` removes that directory.

Alternatively, open `XMT.xcodeproj` in Xcode and run the `XMT` target.

Once running, XMT opens Settings and also requests a menu-bar item. macOS 26 can clip status items on crowded notched menu bars, so reopening XMT always presents Settings as a recovery route. The settings window shows `General` first for Launch at Login and the permission overview, then `Window Mover` for its enabled state, Accessibility status, shortcut, and behavior note, then `Voice` for its enabled state, speech assets, permissions, output and locale settings, input-device priority, and configuration reload.

## Testing

`XMTTests` contains unit tests for window geometry, trigger arbitration, the voice session reducer, input-device selection and the bounded audio queue, recovery reconciliation, transcript commit ordering, and configuration decoding, precedence, and reload. Run them through the shared `XMT` scheme with `just test`; `just check` runs both tests and documentation checks. Capture, speech analysis, the event tap, and the SwiftUI surfaces are not covered.

## Documentation checks

```bash
just docs-check
```

This validates heading structure, opening paragraphs, relative links, heading fragments, and reachability from `docs/README.md`. It needs Node and nothing else — no package manager, lockfile, or dependency install. Without `just`, run `node assets/check-docs.mjs`, which scans the same files by default.

`just check` runs the unit tests and documentation validation.

## Repository layout

- `XMT/App` — app entry point and app delegate
- `XMT/WindowManagement` — window discovery, geometry, movement, coordinate conversion, and the Window Mover lifecycle
- `XMT/VoiceTranscription` — the voice module coordinator plus its `Audio`, `Session`, and `Output` layers
- `XMT/Triggers` — the Fn event tap and the pure trigger arbitrator
- `XMT/Configuration` — config file decoding, settings resolution, and the reloader
- `XMT/HotKeys` — global shortcut names and defaults
- `XMT/Services` — Accessibility permission and reminder handling
- `XMT/Settings` — settings window and its tabs
- `XMT/MenuBar` — menu bar menu
- `XMT/Resources` — `Info.plist`, entitlements, and asset catalog
- `XMTTests` — unit tests
- `docs/` — [product, architecture, specification, and roadmap](docs/README.md)
- `assets/` — repository tooling, currently the documentation checker

Swift package dependency: `KeyboardShortcuts`, up to the next major version from `2.0.0`.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
