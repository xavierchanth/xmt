# XMT roadmap

This is the only place in XMT documentation that records delivery state, implementation gaps, and sequencing. Design belongs in [architecture](../architecture/README.md); released behavior belongs in [specification](../specification/README.md) and ultimately in source and tests. This page names gaps without duplicating the design they refer to.

There are no formal initiative records and no tracker in this repository. This page is a plain statement of where things stand, maintained by hand.

## Delivery state

| Item | State |
|---|---|
| [Window Swapper](../specification/window-swapper.md) | Shipping. The only implemented module. |
| [App shell](../architecture/app-shell.md) | Partial. Menu bar presence, lazy settings window, Accessibility gating, and single-flight actions exist; there is no general module registration, lifecycle, or per-module permission declaration. |
| [Module model](../architecture/modules.md) | Design only. No module abstraction exists in source; Window Swapper is wired directly into the app delegate. |
| Voice Transcription | Not started. |
| Keyboard Customization | Not started. |
| Menu Bar Management | Not started, and not certain to be feasible. |

## Naming and identity gap

The product is [XMT — Xavier's macOS Tweaks](../PRODUCT.md#name-and-terminology), but the Xcode target, scheme, product name, bundle identifier `com.swapper.app`, source directories, entitlements file, and the user-facing `Quit Swapper` menu item are all still named `Swapper`.

Renaming is deferred deliberately and is not part of the documentation work. It touches the bundle identifier, which resets the app's Accessibility grant and its Launch-at-Login registration, so it should be done as one deliberate change rather than incidentally. Until then, treat `Swapper` in the source tree as the historical name of the app that hosts the Window Swapper module.

## Shell gaps

The [app shell design](../architecture/app-shell.md) describes structure that does not exist yet:

- **No module registration or lifecycle.** Shortcut registration happens once in the app delegate at launch. There is no start, stop, or teardown, because nothing needs stopping: the single module holds no OS resources between actions.
- **No per-module permission declaration.** Accessibility is handled as an app-wide concern because it is the only permission any code needs.
- **No enable/disable.** With one module there is nothing to disable.

These gaps are not defects at the current size. They become real work when the second module lands, and the second module should be the thing that forces the abstraction rather than the abstraction being built speculatively.

## Window Swapper gaps

- **Full frame versus visible frame.** Geometry uses the full `NSScreen.frame`, so moved and filled windows extend under the menu bar and behind the Dock. Whether that is the desired behavior is an open question; the current behavior is specified in [screen frames used for geometry](../specification/window-swapper.md#screen-frames-used-for-geometry). Changing it is a behavior change, not a documentation fix.
- **Stale parameter names.** `WindowGeometry` still names parameters `visibleFrame` while callers pass full frames. Renaming is cosmetic but worth doing before anyone trusts the names.
- **Screen order is macOS order.** Cycling follows `NSScreen.screens` order, not physical arrangement. Acceptable today; worth revisiting if a spatial "move left / move right" pairing is ever wanted.
- **Empirical timing constants.** The full-screen delays and deadlines are fixed values that were tuned by observation on one set of displays.
- **Test coverage is geometry-only.** The unit tests cover frame mathematics. Screen selection, permission gating, single-flight behavior, and the full-screen sequence are not covered by automated tests.
- **Command-line tests are not configured.** The shared `Swapper` scheme has no test action, so the test bundle cannot currently be run through a working `xcodebuild test` or `just test` command.

## Sequencing and risk

The intended order, easiest and most valuable first:

1. **Voice Transcription.** Highest personal value and the clearest replacement of a separate app. Two unknowns gate it: whether the intended on-device speech API suits push-to-talk use, and what to do about that API's macOS availability, which is far above the app's current deployment target of 14.0 — raising the target, gating the module by availability, or picking another API are all open. Both are described in [the module's design constraints](../architecture/modules.md#voice-transcription); neither is decided. This module is also what should force the shell's module lifecycle to become real, since it acquires and releases audio resources.
2. **Keyboard Customization.** Start with remapping and a Hyper-key layer. Home-row modifiers come later and separately: tap-versus-hold timing is where such tools become unreliable, and it must not gate the simpler work.
3. **Menu Bar Management.** Last, and the highest risk in the project. macOS offers no adequate public API for controlling other applications' menu bar items, so any implementation depends on fragile Accessibility manipulation that can break across macOS releases. Abandoning this module is an accepted outcome; the fallback is to keep using a dedicated utility for it.

The single-process shape means a badly behaved module can take down the whole app, which is the main reason the riskiest module is last. See [failure domain and isolation](../architecture/app-shell.md#failure-domain-and-isolation).

## Related documentation

- [Product](../PRODUCT.md) — the goals this sequencing serves.
- [Architecture](../architecture/README.md) — the design these gaps are measured against.
- [Specification](../specification/README.md) — what is actually implemented.
