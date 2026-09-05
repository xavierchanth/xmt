# Working in this repository

Conventions for anyone — human or agent — changing XMT. This page covers what the repository is, how to build and check it, and the documentation rules that keep the docs tree trustworthy. Product intent, architecture, and delivery state live in [the documentation tree](docs/README.md), not here.

## What this repository is

A single macOS app: XMT — Xavier's macOS Tweaks, a menu bar utility hosting two compiled-in modules, Window Mover and Voice Transcription. The Xcode project, target, scheme, module, and app product are named `XMT`; the bundle identifier is `com.xavierchanth.xmt`. Three further targets are inert Keyboard Customization feasibility products: the `XMTKeyboardOwner` and `XMTKeyboardWatchdog` command-line boundaries and the `XMTVirtualKeyboard` DriverKit skeleton. They are outside the `XMT` scheme, are not embedded in the app, and perform no input work. See [the build-only evidence](docs/qa/keyboard-driverkit-feasibility.md).

Swift 5, SwiftUI plus AppKit, macOS 26 minimum (`MACOSX_DEPLOYMENT_TARGET = 26.0`), one Swift package dependency (`KeyboardShortcuts`). Voice Transcription additionally uses `Speech`, `AVFoundation`, `CoreAudio`, and `IOBluetooth` from the SDK, and the macOS 26 speech types are used without an availability fallback. The app is not sandboxed. The Xcode project is the build system; there is no `Package.swift`.

Source layout by area: `XMT/App`, `XMT/WindowManagement`, `XMT/VoiceTranscription` (with `Audio`, `Session`, `Output`), `XMT/KeyboardCustomization`, `XMT/Triggers`, `XMT/Configuration`, `XMT/HotKeys`, `XMT/Services`, `XMT/Settings`, `XMT/MenuBar`, `XMT/Resources`, and `XMTTests`. Keyboard Customization currently contains compiled pure resolver, tokenized safety-lifecycle, strict policy, versioned wire-contract, and fake transformation-pipeline models; none is connected to live HID. `XMTKeyboardOwner`, `XMTKeyboardWatchdog`, and `XMTVirtualKeyboard` are separate inert, unsigned build-only targets outside the app scheme and bundle.

## Building and testing

Voice is disabled by default. Pass `XMT_FEATURES=XMT_VOICE` to `xcodebuild` to opt into its runtime and UI. Both flag configurations must continue to build and pass tests; shared Voice source and SDK dependencies remain compiled when the feature is off.

```bash
just build        # Release build into .build/xcode
just test         # unit tests through the shared XMT scheme
just docs-check   # documentation validation
just check        # all currently configured repository checks
just install      # build, replace /Applications/XMT.app, launch
just run          # build and launch without installing
just clean        # remove .build/xcode
just build-dext   # build the inert DriverKit spike target, unsigned; not part of `check`
just build-keyboard-feasibility # build all three inert keyboard feasibility targets
```

`just` recipes are thin wrappers around `xcodebuild` and one Node script; read the justfile and run the command directly if `just` is unavailable. `docs-check` requires only Node — no install step, no lockfile — and `node assets/check-docs.mjs` with no arguments checks the same files the recipe does.

`install` and `run` touch the user's `/Applications` and launch the app. Do not run them to "verify" an unrelated change.

## Code conventions

- Window-management logic stays split between pure geometry (`WindowGeometry`, unit-testable, no AppKit state) and effectful movement (`WindowMover`, `AXWindowInfo`). Put new arithmetic in the pure layer and test it.
- Voice Transcription follows the same split: `TriggerArbitrator`, `VoiceSessionMachine`, `DeviceSelector`, and `Reconciliation` are pure and tested; `VoiceTranscriptionModule` is the only place that performs effects and interprets their commands. Put new decision logic in the pure layer.
- Configuration resolution is total and trap-free: built-in defaults are complete, and every setting resolves to a value plus its source. A file-supplied value must disable its settings control rather than being silently overwritten.
- Accessibility calls fail routinely. Return without action on an unexpected result; do not trap, and do not alert the user for an inapplicable shortcut press.
- User-visible actions run on the main actor and are single-flight: drop overlapping triggers rather than queueing them.
- Do not add idle work — no polling, timers, or background scans while no action is running. The product's [resource posture](docs/architecture/app-shell.md#resource-posture) depends on it. The existing timers are all action-scoped: the Fn hold threshold and secure-input watchdog exist only during a gesture, and the maximum-duration timer only during a recording.
- New capabilities are compiled in, not loaded dynamically. See [the module model](docs/architecture/modules.md).

## Documentation conventions

The docs tree is future-first with an explicit authority order, defined in [the documentation index](docs/README.md#authority-model). Follow it:

- **Architecture describes intent.** It may describe modules that do not exist, but must never imply they do, and must never name an API that has not been written.
- **Specification describes released behavior only.** Verify every claim against source or tests before writing it. A specification page that disagrees with the code is a bug in the page.
- **The roadmap owns delivery state.** Status, gaps, sequencing, and risk go there and nowhere else. Do not add status lines to architecture or specification pages.
- **Source and tests win.** They are the final authority on exact behavior.

Page rules. `just docs-check` mechanically enforces these:

- exactly one H1 per page, and no skipped heading levels;
- a non-blank prose line immediately after the H1 — a list, table, code fence, or subheading there fails;
- every relative link target exists, and every `#fragment` resolves to a heading in the target page, including targets outside the scanned roots;
- every page under `docs/` is reachable by following links from `docs/README.md` through other `docs/` pages;
- no heading named `Contents` or `Table of contents`;
- no line beginning with `last updated` metadata.

These rules are **not** checked and remain your responsibility: sentence-case headings; whether the opening paragraph actually states purpose and scope; whether index links are annotated with a reason; whether a page links to an authority instead of restating it; and every claim of fact.

When behavior changes, update the specification page in the same change. When a gap closes, update [the roadmap](docs/roadmap/README.md).

## Scope discipline

Keep documentation restructuring separate from behavior changes. Do not rename targets, bundle identifiers, or source directories as a side effect of another task.
