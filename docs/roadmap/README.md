# XMT roadmap

This is the only place in XMT documentation that records delivery state, implementation gaps, and sequencing. Design belongs in [architecture](../architecture/README.md); released behavior belongs in [specification](../specification/README.md) and ultimately in source and tests. This page names gaps without duplicating the design they refer to.

There are no formal initiative records and no tracker in this repository. This page is a plain statement of where things stand, maintained by hand.

## Delivery state

| Item | State |
|---|---|
| [Window Mover](../specification/window-mover.md) | Shipping. |
| [Voice Transcription](../specification/voice-transcription.md) | Implemented and integrated, **not yet validated on hardware**. Triggers, capture, speech analysis, recovery, commit, paste, menu, settings, and configuration are wired into the app and specified; no part of the runtime path has been exercised against a real microphone, a real Speech model download, or a real Fn press. See [validation gaps](#voice-transcription-validation-gaps). |
| [Configuration](../specification/configuration.md) | Implemented for both modules, with explicit reloads only. File watching remains unimplemented; see [configuration gaps](#configuration-gaps). |
| [App shell](../architecture/app-shell.md) | Partial. Menu bar presence, lazy settings, shared Accessibility presentation, single-flight actions, shared configuration resolution, and two compiled-in module lifecycles exist; there is no general registration list or per-module permission declaration API. |
| [Module model](../architecture/modules.md) | Partial. Both modules have their own compiled-in lifecycle manager and settings boundary; no general module abstraction exists. |
| Keyboard Customization | Not started. |
| Menu Bar Management | Not started, and not certain to be feasible. |

"Implemented" here means the code exists, compiles into the shipping target, and is reachable from the app. It does not mean the behavior has been observed working.

## Identity migration

The project, target, scheme, source and test directories, app product, and bundle identifier now use XMT. The former `Swapper` identity is historical. Because macOS keys privacy and service registrations to app identity, this rename requires a fresh Accessibility grant and Launch-at-Login registration; XMT does not attempt unsupported migration or TCC manipulation.

## Shell gaps

The first compiled-in lifecycle seam now persists Window Mover's single enabled state and gates every shortcut callback dynamically. Disabling releases the active global hot key through `KeyboardShortcuts.disable`, and re-enabling reacquires it through `KeyboardShortcuts.enable`. The current implementation leaves its callback closure installed as inert library state and retains a defensive enabled-state guard; it does not yet use KeyboardShortcuts' available `removeHandler(for:)` API. The guard returns before coordination, permission checks, or window work if invoked while disabled. The module acquires no other passive resource.

Voice Transcription added the second compiled-in lifecycle seam: enabling it installs an event tap, disabling it and app termination release the tap, the capture engine, the analyzer, the timers, and the asset reservation. That is the concrete resource-releasing module the shell design was waiting for, but it was integrated as a second singleton rather than through a shared abstraction.

There is still no general module registration list or per-module permission declaration API. Those abstractions remain deferred; two hand-wired modules are now enough evidence to design one, and doing so is the natural next shell increment.

## Voice Transcription validation gaps

The module is implemented, wired into the app delegate, the menu, Settings, and configuration, and it builds into the Release target. What is missing is evidence that it works. **Nothing below has been observed on hardware**, and the [specification](../specification/voice-transcription.md) states only what the code does, never what a device did.

Unvalidated by manual exercise:

- **Microphone capture.** No recording has been made. Device binding by UID, the hardware tap format, the 1-second first-buffer deadline, the 32-buffer queue depth, and CAF recovery writing are untested against real audio hardware.
- **Speech analysis and assets.** No asset status check, download, reservation, or transcription has been run. Whether the progressive-transcription preset, the format conversion, and the 5-second finalization bound behave as intended in practice is unknown, as is whether the queue depth and finalization bound are the right values.
- **Fn gestures.** The event tap, the 150 ms hold threshold, Fn-Space consumption, the secure-input watchdog, and tap re-enable after a system disable have only been exercised as pure reducers in tests. Whether the default threshold feels right, and whether consuming Fn-Space breaks any expected macOS behavior, is unknown.
- **Bluetooth and AirPods.** The fail-closed name matching has never been run against a real paired headset. Whether AirPods report a usable Core Audio name, whether the connected check is accurate at the moment of selection, and whether switching to a headset microphone degrades transcription are all open.
- **Auto-paste.** The synthetic Command-V to the PID captured at arm time has not been tried against a real editor, and the assumption that the frontmost application at arm time is still the right target at commit time is unverified.
- **Permission prompts.** The launch-silent, contextual request flow for Microphone, Input Monitoring, Accessibility, and any Speech framework authorization has not been walked through on a machine without the grants. The relevant usage-description strings are present, but whether SpeechAnalyzer presents a separate speech-recognition prompt remains unobserved.
- **Recovery in anger.** Reconciliation is well covered by tests over a fake store, but no real interrupted session has been recovered, retried, or deleted.

Known implementation gaps, independent of validation:

- **No settings control for two values.** The Fn hold threshold and maximum session duration are file-only.
- **Auto-paste requires a captured target.** Retries have no trustworthy target, and a live session armed while XMT is frontmost deliberately captures none. In either case the transcript is committed to the clipboard and optional cache without synthesizing a paste.
- **Coverage stops at the pure layers.** Trigger arbitration, the session reducer, device selection, the bounded queue, reconciliation, commit ordering, and configuration are unit-tested. Capture, the analyzer session, the event tap, the module coordinator, and every SwiftUI surface are not.

Until at least a recording, a transcription, and a paste have been performed by hand, Voice Transcription should be described as implemented, not as shipping.

## Configuration gaps

- **Reload is explicit, not observed.** [Declarative configuration](../architecture/configuration.md#loading-and-reloads) intends file-system observation with coalescing. The implementation reloads at launch, whenever the app becomes active, and on a Settings button. Nothing watches the file, which is the intended design's remaining delta and not a defect in the current behavior.
- **Diagnostics surface only in Voice settings.** A malformed file that also governs Window Mover reports its diagnostic on the Voice tab.

## Window Mover gaps

- **Full frame versus visible frame.** Geometry uses the full `NSScreen.frame`, so moved and filled windows extend under the menu bar and behind the Dock. Whether that is the desired behavior is an open question; the current behavior is specified in [screen frames used for geometry](../specification/window-mover.md#screen-frames-used-for-geometry). Changing it is a behavior change, not a documentation fix.
- **Stale parameter names.** `WindowGeometry` still names parameters `visibleFrame` while callers pass full frames. Renaming is cosmetic but worth doing before anyone trusts the names.
- **Screen order is macOS order.** Cycling follows `NSScreen.screens` order, not physical arrangement. Acceptable today; worth revisiting if a spatial "move left / move right" pairing is ever wanted.
- **Empirical timing constants.** The full-screen delays and deadlines are fixed values that were tuned by observation on one set of displays.
- **Window behavior coverage is geometry-only.** The shared XMT scheme also runs trigger, configuration, and audio-selection infrastructure tests, but screen selection, permission gating, Window Mover lifecycle gating, single-flight behavior, and the full-screen sequence remain uncovered.

## Sequencing and risk

The intended order, easiest and most valuable first:

1. **Voice Transcription.** Implemented and integrated; its behavior is specified in [the Voice Transcription specification](../specification/voice-transcription.md). The remaining work is not more code but hardware validation, listed in [validation gaps](#voice-transcription-validation-gaps) above. Nothing else should start before a real recording has been made, transcribed, and pasted, because that exercise is the only thing that can tell whether the threshold, queue depth, timeouts, and device rules were chosen sensibly — and because the module holds a microphone and an event tap, which is exactly the kind of thing that should not sit unverified in a resident menu bar app.
2. **Keyboard Customization.** Start with remapping and a Hyper-key layer. Home-row modifiers come later and separately: tap-versus-hold timing is where such tools become unreliable, and it must not gate the simpler work.
3. **Menu Bar Management.** Last, and the highest risk in the project. macOS offers no adequate public API for controlling other applications' menu bar items, so any implementation depends on fragile Accessibility manipulation that can break across macOS releases. Abandoning this module is an accepted outcome; the fallback is to keep using a dedicated utility for it.

The single-process shape means a badly behaved module can take down the whole app, which is the main reason the riskiest module is last. See [failure domain and isolation](../architecture/app-shell.md#failure-domain-and-isolation).

## Related documentation

- [Product](../PRODUCT.md) — the goals this sequencing serves.
- [Architecture](../architecture/README.md) — the design these gaps are measured against.
- [Specification](../specification/README.md) — what is actually implemented.
