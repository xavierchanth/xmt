# XMT roadmap

This is the only place in XMT documentation that records delivery state, implementation gaps, and sequencing. Design belongs in [architecture](../architecture/README.md); released behavior belongs in [specification](../specification/README.md) and ultimately in source and tests. This page names gaps without duplicating the design they refer to.

There are no formal initiative records and no tracker in this repository. This page is a plain statement of where things stand, maintained by hand.

## Delivery state

| Item | State |
|---|---|
| [Window Mover](../specification/window-mover.md) | Shipping. The only implemented module. |
| [App shell](../architecture/app-shell.md) | Partial. Menu bar presence, lazy settings, shared Accessibility presentation, single-flight actions, and the first compiled-in module lifecycle exist; there is no general registration list or per-module permission declaration API. |
| [Module model](../architecture/modules.md) | Partial. Window Mover has a small compiled-in lifecycle manager and settings boundary; no general module abstraction exists. |
| Voice Transcription | Infrastructure in progress. Fn trigger arbitration, declarative configuration, prioritized input-device selection, bounded audio handoff, and incremental recovery capture exist with unit-tested pure layers, but no module, speech session, recovery orchestration, transcript output, settings, or menu integration is wired. |
| Keyboard Customization | Not started. |
| Menu Bar Management | Not started, and not certain to be feasible. |

## Identity migration

The project, target, scheme, source and test directories, app product, and bundle identifier now use XMT. The former `Swapper` identity is historical. Because macOS keys privacy and service registrations to app identity, this rename requires a fresh Accessibility grant and Launch-at-Login registration; XMT does not attempt unsupported migration or TCC manipulation.

## Shell gaps

The first compiled-in lifecycle seam now persists Window Mover's single enabled state and gates every shortcut callback dynamically. Disabling releases the active global hot key through `KeyboardShortcuts.disable`, and re-enabling reacquires it through `KeyboardShortcuts.enable`. The current implementation leaves its callback closure installed as inert library state and retains a defensive enabled-state guard; it does not yet use KeyboardShortcuts' available `removeHandler(for:)` API. The guard returns before coordination, permission checks, or window work if invoked while disabled. The module acquires no other passive resource.

There is still no general module registration list or per-module permission declaration API. Those abstractions remain deferred until another compiled-in module provides concrete requirements.

## Window Mover gaps

- **Full frame versus visible frame.** Geometry uses the full `NSScreen.frame`, so moved and filled windows extend under the menu bar and behind the Dock. Whether that is the desired behavior is an open question; the current behavior is specified in [screen frames used for geometry](../specification/window-mover.md#screen-frames-used-for-geometry). Changing it is a behavior change, not a documentation fix.
- **Stale parameter names.** `WindowGeometry` still names parameters `visibleFrame` while callers pass full frames. Renaming is cosmetic but worth doing before anyone trusts the names.
- **Screen order is macOS order.** Cycling follows `NSScreen.screens` order, not physical arrangement. Acceptable today; worth revisiting if a spatial "move left / move right" pairing is ever wanted.
- **Empirical timing constants.** The full-screen delays and deadlines are fixed values that were tuned by observation on one set of displays.
- **Window behavior coverage is geometry-only.** The shared XMT scheme also runs trigger, configuration, and audio-selection infrastructure tests, but screen selection, permission gating, Window Mover lifecycle gating, single-flight behavior, and the full-screen sequence remain uncovered.

## Sequencing and risk

The intended order, easiest and most valuable first:

1. **Voice Transcription.** Highest personal value and the clearest replacement of a separate app. The design decision is to target macOS 26 directly and integrate Apple's SpeechAnalyzer/SpeechTranscriber, with hold-Fn push-to-talk, Fn-Space toggle, versioned declarative configuration, ordered input devices plus an independent system-default fallback, bounded temporary recovery, a last transcript, and optional auto-paste. Trigger, configuration, and audio-capture infrastructure now exist but remain disconnected from the app; session, recovery, output, and integration are next. Integration must confirm through public Apple documentation whether SpeechAnalyzer/SpeechTranscriber requires `NSSpeechRecognitionUsageDescription`; the installed macOS 26 SDK exposes the APIs but does not itself establish that privacy key requirement. `NSMicrophoneUsageDescription` is present, and Bluetooth usage is disclosed because input selection reads paired-device connection state without initiating connections. Asset/session failure modes and hardware validation remain integration risks, not reasons to retain macOS 14 compatibility. This module is also what should force the shell's module lifecycle to become real, since it acquires and releases audio resources.
2. **Keyboard Customization.** Start with remapping and a Hyper-key layer. Home-row modifiers come later and separately: tap-versus-hold timing is where such tools become unreliable, and it must not gate the simpler work.
3. **Menu Bar Management.** Last, and the highest risk in the project. macOS offers no adequate public API for controlling other applications' menu bar items, so any implementation depends on fragile Accessibility manipulation that can break across macOS releases. Abandoning this module is an accepted outcome; the fallback is to keep using a dedicated utility for it.

The single-process shape means a badly behaved module can take down the whole app, which is the main reason the riskiest module is last. See [failure domain and isolation](../architecture/app-shell.md#failure-domain-and-isolation).

## Related documentation

- [Product](../PRODUCT.md) — the goals this sequencing serves.
- [Architecture](../architecture/README.md) — the design these gaps are measured against.
- [Specification](../specification/README.md) — what is actually implemented.
