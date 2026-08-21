# XMT — Xavier's macOS Tweaks

XMT is a personal macOS menu bar app that collects chosen macOS behavior changes into one process, so there is one background app to install, permission, configure, and remember instead of one per tweak. This README covers what ships today and how to build, run, and test it; [the documentation tree](docs/README.md) covers product intent, architecture, and roadmap.

The Xcode target, scheme, and bundle identifier are still named `Swapper`. That rename is an open gap, not a second product — see [naming and identity](docs/roadmap/README.md#naming-and-identity-gap).

## What ships today

One module, **Window Swapper**: a global shortcut (default **Option-Space**) that moves the focused window to the next display, wrapping around, preserving relative geometry, and handling native full-screen windows.

Supporting behavior:

- Lives in the menu bar as an `LSUIElement` app with no Dock icon.
- Rebindable global shortcut powered by [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts).
- Accessibility permission prompt at launch, with status and a re-request button in Settings.
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

That recipe quits a running copy, replaces `/Applications/Swapper.app`, and launches the result. On first launch, grant Accessibility access when macOS prompts, then open `Settings...` from the menu bar icon to configure the shortcut.

To build and launch without installing:

```bash
just run
```

Both build into `.build/xcode`; `just clean` removes that directory.

Alternatively, open `Swapper.xcodeproj` in Xcode and run the `Swapper` target.

Once running, the app appears in the menu bar. The settings window has two tabs: `Shortcuts` records the global hotkey, and `General` toggles Launch at Login and shows Accessibility permission status.

## Testing

`SwapperTests` contains unit tests for window geometry mathematics. The shared `Swapper` scheme does not currently include a test action, so command-line test execution is not configured. This is tracked as a repository gap rather than exposed through a non-working `just` recipe.

## Documentation checks

```bash
just docs-check
```

This validates heading structure, opening paragraphs, relative links, heading fragments, and reachability from `docs/README.md`. It needs Node and nothing else — no package manager, lockfile, or dependency install. Without `just`, run `node assets/check-docs.mjs`, which scans the same files by default.

`just check` runs all currently configured repository checks. At present, that is the documentation check.

## Repository layout

- `Swapper/App` — app entry point and app delegate
- `Swapper/WindowManagement` — window discovery, geometry, movement, and coordinate conversion
- `Swapper/HotKeys` — global shortcut names and defaults
- `Swapper/Services` — Accessibility permission and reminder handling
- `Swapper/Settings` — settings window and its tabs
- `Swapper/MenuBar` — menu bar menu
- `SwapperTests` — unit tests
- `docs/` — [product, architecture, specification, and roadmap](docs/README.md)
- `assets/` — repository tooling, currently the documentation checker

Swift package dependency: `KeyboardShortcuts`, up to the next major version from `2.0.0`.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
