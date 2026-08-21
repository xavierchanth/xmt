# Working in this repository

Conventions for anyone — human or agent — changing XMT. This page covers what the repository is, how to build and check it, and the documentation rules that keep the docs tree trustworthy. Product intent, architecture, and delivery state live in [the documentation tree](docs/README.md), not here.

## What this repository is

A single macOS app: XMT — Xavier's macOS Tweaks, a menu bar utility hosting one implemented module, Window Mover. The Xcode project, target, scheme, module, and app product are named `XMT`; the bundle identifier is `com.xavierchanth.xmt`.

Swift 5, SwiftUI plus AppKit, macOS 14 minimum, one Swift package dependency (`KeyboardShortcuts`). The Xcode project is the build system; there is no `Package.swift`.

## Building and testing

```bash
just build        # Release build into .build/xcode
just docs-check   # documentation validation
just check        # all currently configured repository checks
just install      # build, replace /Applications/XMT.app, launch
just run          # build and launch without installing
just clean        # remove .build/xcode
```

`just` recipes are thin wrappers around `xcodebuild` and one Node script; read the justfile and run the command directly if `just` is unavailable. `docs-check` requires only Node — no install step, no lockfile — and `node assets/check-docs.mjs` with no arguments checks the same files the recipe does.

`install` and `run` touch the user's `/Applications` and launch the app. Do not run them to "verify" an unrelated change.

## Code conventions

- Window-management logic stays split between pure geometry (`WindowGeometry`, unit-testable, no AppKit state) and effectful movement (`WindowMover`, `AXWindowInfo`). Put new arithmetic in the pure layer and test it.
- Accessibility calls fail routinely. Return without action on an unexpected result; do not trap, and do not alert the user for an inapplicable shortcut press.
- User-visible actions run on the main actor and are single-flight: drop overlapping triggers rather than queueing them.
- Do not add idle work — no polling, timers, or background scans while no action is running. The product's [resource posture](docs/architecture/app-shell.md#resource-posture) depends on it.
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
