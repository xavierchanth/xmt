# XMT — Xavier's macOS Tweaks

XMT is a personal macOS menu bar app that collects chosen macOS behavior changes into one process, so there is one background app to install, permission, configure, and remember instead of one per tweak. This README covers what ships today and how to build, run, and test it; [the documentation tree](docs/README.md) covers product intent, architecture, and roadmap.

## What ships today

One module, **Window Mover**: a global shortcut (default **Option-Space**) that moves the focused window to the next display, wrapping around, preserving relative geometry, and handling native full-screen windows.

Supporting behavior:

- Lives in the menu bar as an `LSUIElement` app with no Dock icon.
- Rebindable global shortcut powered by [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts).
- Contextual Accessibility status and request actions in Settings; launch does not prompt.
- Launch at Login through `SMAppService`.

Voice Transcription, Keyboard Customization, and Menu Bar Management are **planned, not implemented**. See [the module inventory](docs/architecture/modules.md#module-inventory).

## Status

Maintained for personal use. There are no plans to publish it and no support commitment.

## Requirements

- macOS 14 or later
- Xcode 15 or later
- Accessibility permission granted to the app

## Installing

With [`just`](https://github.com/casey/just) installed, build a Release app and copy it to `/Applications`:

```bash
just install
```

That recipe quits a running copy, replaces `/Applications/XMT.app`, and launches the result. Open `Settings...` from the menu bar icon to configure Window Mover and grant Accessibility access contextually.

To build and launch without installing:

```bash
just run
```

Both build into `.build/xcode`; `just clean` removes that directory.

Alternatively, open `XMT.xcodeproj` in Xcode and run the `XMT` target.

Once running, the app appears in the menu bar. The settings window shows `General` first for Launch at Login and the permission overview, then `Window Mover` for its enabled state, Accessibility status, shortcut, and behavior note.

## Testing

`XMTTests` contains unit tests for window geometry mathematics. Run them through the shared `XMT` scheme with `just test`; `just check` runs both tests and documentation checks.

## Documentation checks

```bash
just docs-check
```

This validates heading structure, opening paragraphs, relative links, heading fragments, and reachability from `docs/README.md`. It needs Node and nothing else — no package manager, lockfile, or dependency install. Without `just`, run `node assets/check-docs.mjs`, which scans the same files by default.

`just check` runs all currently configured repository checks. 

## Repository layout

- `XMT/App` — app entry point and app delegate
- `XMT/WindowManagement` — window discovery, geometry, movement, and coordinate conversion
- `XMT/HotKeys` — global shortcut names and defaults
- `XMT/Services` — Accessibility permission and reminder handling
- `XMT/Settings` — settings window and its tabs
- `XMT/MenuBar` — menu bar menu
- `XMTTests` — unit tests
- `docs/` — [product, architecture, specification, and roadmap](docs/README.md)
- `assets/` — repository tooling, currently the documentation checker

Swift package dependency: `KeyboardShortcuts`, up to the next major version from `2.0.0`.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
