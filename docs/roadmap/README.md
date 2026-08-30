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
| [Keyboard Customization](../architecture/keyboard-customization.md) | **T-1 Stage 1 pure/build-only work complete.** Pure tap-hold resolution, protected-input safety lifecycle with a threshold circuit breaker, and normalized synthetic device matching compile into the app but have no effectful owner or live HID connection. An inert virtual-keyboard DriverKit target compiles unsigned outside the app; signing is blocked on entitlements Apple has not been asked for. No live device test has begun. See [feasibility gates](#keyboard-customization-feasibility). |
| Menu Bar Management | Cross-app management is closed as a public-API no-go. XMT-own-icon behavior remains app-shell territory. |

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
- **Paste actions.** Synthetic Command-V has not been tried against a real editor, either for auto-paste to the PID captured at arm time or paste latest to the application focused at invocation time. The assumption that the frontmost application at arm time is still the right auto-paste target at commit time is unverified.
- **Permission prompts.** The launch-silent, contextual request flow for Microphone, Input Monitoring, Accessibility, and any Speech framework authorization has not been walked through on a machine without the grants. The relevant usage-description strings are present, but whether SpeechAnalyzer presents a separate speech-recognition prompt remains unobserved.
- **Recovery in anger.** Reconciliation is well covered by tests over a fake store, but no real interrupted session has been recovered, retried, or deleted.

Known implementation gaps, independent of validation:

- **No settings control for two values.** The Fn hold threshold and maximum session duration are file-only.
- **Auto-paste requires a captured target.** Retries have no trustworthy target, and a live session armed while XMT is frontmost deliberately captures none. In either case the transcript is committed to the clipboard and optional cache without automatic paste; paste latest can subsequently target the application focused when that separate command is invoked.
- **Coverage stops at the pure layers.** Trigger arbitration, the session reducer, device selection, the bounded queue, reconciliation, commit ordering, and configuration are unit-tested. Capture, the analyzer session, the event tap, the module coordinator, and every SwiftUI surface are not.

Until at least a recording, a transcription, and a paste have been performed by hand, Voice Transcription should be described as implemented, not as shipping. The deferred exercise is recorded as a repeatable [Voice hardware QA checklist](../qa/voice-transcription.md).

## Future Voice history and clients

The first history increment retains and pastes only one latest transcript. A searchable, bounded transcript history with a native XMT panel is deferred; it must not be inferred from the one-slot `last-transcript.txt` cache.

A Raycast client is also deferred. It must consume an app-owned, stable JSON boundary designed for external clients rather than reading XMT's cache or any future internal history store directly. Versioning, lifetime, privacy, and write ownership for that boundary must be settled before the client ships.

## Configuration gaps

- **Reload is explicit, not observed.** [Declarative configuration](../architecture/configuration.md#loading-and-reloads) intends file-system observation with coalescing. The implementation reloads at launch, whenever the app becomes active, and on a Settings button. Nothing watches the file, which is the intended design's remaining delta and not a defect in the current behavior.
- **Diagnostics surface only in Voice settings.** A malformed file that also governs Window Mover reports its diagnostic on the Voice tab.

## Keyboard Customization feasibility

The approved T-1 spike is ready to test whether the protected-input architecture in [Keyboard Customization](../architecture/keyboard-customization.md) is feasible. “Approved” selects a direction; it does not assert system-extension entitlement approval, successful installation, seizure release behavior, or working hardware interception.

The gates are sequential and separately authorized:

1. **Build-only / no-live-device stage.** Create only enough spike scaffolding to prove the app, task-scoped seizure owner, HIDDriverKit virtual keyboard, XPC lease, and independent watchdog can compile, sign in the available development environment, and package coherently. Do not open or seize any keyboard and do not activate the design against live input.

   Stage 1 pure/build-only work is complete. Pure tap-hold resolution, protected-input safety lifecycle, and normalized synthetic identity matching compile into `XMT` and are unit-tested, but no effectful seizure owner, XPC lease, watchdog, device enumeration, or HID connection exists. The inert `XMTVirtualKeyboard` DriverKit target compiles and packages unsigned, declares no `IOKitPersonalities`, and is not embedded in `XMT.app`. Signing is blocked — the four DriverKit entitlements the design needs are restricted, none has been requested from or granted by Apple, no provisioning profile carrying them exists, and there is no Developer ID identity on the machine. Observations are in [Keyboard DriverKit build-only evidence](../qa/keyboard-driverkit-feasibility.md).
2. **External-keyboard test.** Proceed only after explicit authorization following review of build-only results and a recovery procedure. Test one expendable external keyboard first, with all other devices excluded.
3. **Built-in-keyboard test.** Proceed only under a second explicit authorization after external-device results and recovery behavior have been reviewed. Direct dext ownership remains out of scope, as do login-window and FileVault interception.

Each stage records observations rather than guarantees. Process termination is expected to release task-scoped seizure, but no release guarantee or time bound may be inferred. No stage may claim that Apple will grant an entitlement or approve distribution.

## Other potential directions

Independent mouse/trackpad scrolling direction is a potential future capability, not planned work. It has no approved design, sequence, or delivery commitment.

## Window Mover gaps

- **Full frame versus visible frame.** Geometry uses the full `NSScreen.frame`, so moved and filled windows extend under the menu bar and behind the Dock. Whether that is the desired behavior is an open question; the current behavior is specified in [screen frames used for geometry](../specification/window-mover.md#screen-frames-used-for-geometry). Changing it is a behavior change, not a documentation fix.
- **Stale parameter names.** `WindowGeometry` still names parameters `visibleFrame` while callers pass full frames. Renaming is cosmetic but worth doing before anyone trusts the names.
- **Screen order is macOS order.** Cycling follows `NSScreen.screens` order, not physical arrangement. Acceptable today; worth revisiting if a spatial "move left / move right" pairing is ever wanted.
- **Empirical timing constants.** The full-screen delays and deadlines are fixed values that were tuned by observation on one set of displays.
- **Window behavior coverage is geometry-only.** The shared XMT scheme also runs trigger, configuration, and audio-selection infrastructure tests, but screen selection, permission gating, Window Mover lifecycle gating, single-flight behavior, and the full-screen sequence remain uncovered.

## Sequencing and risk

The intended order, easiest and most valuable first:

1. **Voice Transcription.** Implemented and integrated; its behavior is specified in [the Voice Transcription specification](../specification/voice-transcription.md). The remaining work is not more code but hardware validation, listed in [validation gaps](#voice-transcription-validation-gaps) above. Nothing else should start before a real recording has been made, transcribed, and pasted, because that exercise is the only thing that can tell whether the threshold, queue depth, timeouts, and device rules were chosen sensibly — and because the module holds a microphone and an event tap, which is exactly the kind of thing that should not sit unverified in a resident menu bar app.
2. **Keyboard Customization.** Run the T-1 feasibility gates above: build-only and no-live-device first, then separately authorized external-keyboard and built-in-keyboard tests. The two user-visible capabilities belong to one module but remain independently enabled. Safety evidence, not feature ordering, controls progression.
3. **Menu Bar Management.** Cross-app control is closed as a public-API no-go; unsupported Accessibility/layout manipulation will not be pursued. XMT's own icon behavior remains ordinary shell work if a need arises.

Ordinary modules share the app-process failure domain. Keyboard Customization is the explicit isolated-process/system-extension safety exception; that isolation carries its own feasibility and recovery risks. See [failure domain and isolation](../architecture/app-shell.md#failure-domain-and-isolation).

## Related documentation

- [Product](../PRODUCT.md) — the goals this sequencing serves.
- [Architecture](../architecture/README.md) — the design these gaps are measured against.
- [Specification](../specification/README.md) — what is actually implemented.
