# XMT product

XMT — Xavier's macOS Tweaks is a personal macOS utility that collects chosen macOS behavior changes into one menu bar app. This page owns the product promise, the users, the goals and non-goals, and the reasoning behind the single-process shape. It does not describe implementation; see [architecture](architecture/README.md) for intended structure and [the roadmap](roadmap/README.md) for what exists today.

## Name and terminology

The product is **XMT — Xavier's macOS Tweaks**. "macOS" always uses Apple's capitalization. Capabilities inside XMT are called **modules**. The named modules are **Window Mover**, **Voice Transcription**, **Keyboard Customization**, and **Menu Bar Management**; which of them exist is [the roadmap](roadmap/README.md)'s to say.

The app, Xcode project, target, scheme, and bundle identity all use XMT.

## Users

XMT is built for its author's own machine. There is no support commitment, no distribution channel, and no external compatibility promise. Documentation is written so a future maintainer — most likely the same person a year later — can re-enter the codebase quickly.

## Goals

- **Fewer separate background apps.** One resident process instead of one per tweak.
- **Less app exploration and management.** Fewer utilities to discover, evaluate, update, re-grant permissions to, and remember the shortcuts of.
- **One coherent place for chosen macOS behavior.** Shared settings surface, shared permission handling, shared shortcut vocabulary.
- **Lightweight passive resource use.** While idle, XMT should sit in the menu bar doing effectively nothing until a shortcut fires.

## Non-goals

- Not a general window manager, tiling engine, or automation platform.
- Not a replacement for macOS features that already work well.
- Not a published or supported product in its current form.
- Not a plugin host: modules are compiled in, not loaded dynamically. See [the module model](architecture/modules.md).

## Why one app instead of several

Each additional menu bar utility carries fixed costs that have nothing to do with the feature it provides: a separate resident process, a separate Accessibility or Input Monitoring grant to maintain, a separate settings window, a separate update path, and one more icon competing for menu bar space. Consolidating the tweaks the author actually uses removes those repeated costs even when the underlying feature work is unchanged.

Consolidation also has a cost, and XMT accepts it deliberately: a single process is a single failure domain. The architecture answers that with per-module isolation rather than by splitting processes; see [the app shell](architecture/app-shell.md#failure-domain-and-isolation).

### Rough resource observations

The figures below are **casual observations from Activity Monitor on the author's machine, not benchmarks, budgets, or guarantees.** They were not collected under controlled conditions, they are not reproducible as stated, and no XMT behavior depends on them. They are recorded only because they motivated the consolidation goal.

| App observed | Rough resident memory |
|---|---|
| Hidden Bar | nearly 400 MB |
| Voice Notes | about 62 MB |
| HyperKey | about 37 MB |
| XMT (historical pre-rename build) | usually around 24 MB, observed below 35 MB |

The XMT figure is a menu-bar-idle observation. Any growth after opening the Settings window was **not measured**, and no attempt has been made to attribute it. It is plausible that instantiating SwiftUI view and window machinery accounts for some of it, but that is an untested guess, not a finding — the mechanism has not been profiled, the effect size is unknown, and it may not exist at all. Do not cite it as an explanation.

No performance guarantee follows from any of this. The commitment XMT makes is architectural — do no periodic work while idle, hold no resources a module is not actively using — not numeric. That commitment is stated in [the app shell](architecture/app-shell.md#resource-posture).

## Related documentation

- [Architecture](architecture/README.md) — how the intended shell and modules realize these goals.
- [Specification](specification/README.md) — normative behavior of the implemented modules.
- [Roadmap](roadmap/README.md) — what is not built yet, and in what order.
