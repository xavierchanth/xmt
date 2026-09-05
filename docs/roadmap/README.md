# XMT roadmap

This is the only place in XMT documentation that records delivery state, implementation gaps, and sequencing. Design belongs in [architecture](../architecture/README.md); released behavior belongs in [specification](../specification/README.md) and ultimately in source and tests. This page names gaps without duplicating the design they refer to.

There are no formal initiative records and no tracker in this repository. This page is a plain statement of where things stand, maintained by hand.

## Delivery state

| Item | State |
|---|---|
| [Window Mover](../specification/window-mover.md) | Shipping. |
| [Voice Transcription](../specification/voice-transcription.md) | Implemented and integrated, **not yet validated on hardware**. Voice UX v2 includes an accessible zero-or-more action list with add/edit/remove/reorder and tokenized capture ownership; bindings, cancellation privacy, output modes, system locale resolution, asset gating, overlay, capture, speech analysis, recovery, menu, settings, and configuration are wired into the app and specified; no part of the runtime path has been exercised against a real microphone, a real Speech model download, or a real Fn press. See [validation gaps](#voice-transcription-validation-gaps). |
| [Configuration](../specification/configuration.md) | Implemented for both modules, with explicit reloads only. File watching remains unimplemented; see [configuration gaps](#configuration-gaps). |
| [App shell](../architecture/app-shell.md) | Partial. Menu bar presence, an AppKit-owned reusable Settings recovery window, stable development signing, safer replacement installation, shared Accessibility presentation, single-flight actions, shared configuration resolution, a validated compiled-in module catalog with permission declarations, and centralized ordinary-shortcut routing exist. Fn-provider and capture ownership are still module-local. macOS 26 may still clip XMT's status item on crowded notched menu bars, so direct launch presents Settings as the recovery surface. |
| [Module model](../architecture/modules.md) | Partial. A compiled-in catalog validates module identity, permission metadata, and semantic-action ownership, and an effectful registry owns dispatch and process lifecycle fan-out. Each module still has its own concrete lifecycle manager and settings boundary rather than implementing one complete module contract. |
| [Keyboard Customization](../architecture/keyboard-customization.md) | **T-1 code-only and unsigned process-boundary work complete; signed coherent Stage 1 packaging remains blocked.** Validated tap-hold resolution, session-bound protected-input ownership, strict policy decoding, a bounded versioned wire contract, fail-closed inventory matching, and an injected transformation/runtime pipeline compile into the app and are tested with fakes. Separate inert owner, watchdog, and virtual-keyboard targets build as universal unsigned products through the feasibility scheme. They are not embedded, connected, registered, or activated; no live device test has begun. See [feasibility gates](#keyboard-customization-feasibility). |
| Menu Bar Management | Cross-app management is closed as a public-API no-go. XMT-own-icon behavior remains app-shell territory. |

"Implemented" here means the code exists, compiles into the shipping target, and is reachable from the app. It does not mean the behavior has been observed working.

## Identity migration

The project, target, scheme, source and test directories, app product, and bundle identifier now use XMT. The former `Swapper` identity is historical. Because macOS keys privacy and service registrations to app identity, this rename requires a fresh Accessibility grant and Launch-at-Login registration; XMT does not attempt unsupported migration or TCC manipulation.

## Shell gaps

The first compiled-in lifecycle seam persists Window Mover's enabled state and gates its shortcut. Disabling now cancels an in-flight move, disables the registration, and removes the KeyboardShortcuts handler; re-enabling reinstalls it. Initial file configuration is read before Window Mover acquires a shortcut, preventing a managed disable or replacement from briefly exposing the local binding.

Voice Transcription added the second compiled-in lifecycle seam: enabling it installs an event tap, disabling it and app termination release the tap, the capture engine, the analyzer and action-scoped timers. Apple-managed speech assets are status-gated and are not reserved per session. A shared registry now owns startup, shutdown, configuration fan-out, and semantic-action dispatch for both concrete module managers; their internal lifecycle shapes remain module-specific.

A validated compiled-in catalog now declares module identities, permissions, and semantic actions. A shell-owned configuration coordinator owns reload serialization, diagnostics, effective-snapshot publication, and registry application; an aggregate of module-specific settings adapters supplies local values and restores shortcut storage, so neither module acts as the other's persistence boundary. One standard-shortcut provider now owns every ordinary KeyboardShortcuts handler and its enabled state, feeds a pure generation-gated router, and sends semantic events through the module registry. The input-routing boundary remains incomplete because Voice still owns its Fn observer and shortcut-capture lease. The next shell increment is to move those two control-plane responsibilities out of the Voice singleton without changing released behavior. Keyboard Customization remains a separate lower-level transformation pipeline and must not become another consumer inside that router.

## Voice Transcription validation gaps

Voice is disabled by default through the build-time `XMT_VOICE` feature gate. Enable it with `XMT_FEATURES=XMT_VOICE` for the validation below; this gate does not close any hardware-validation gaps.

The module is implemented, wired into the app delegate, the menu, Settings, and configuration, and it builds into the Release target. What is missing is evidence that it works. **Nothing below has been observed on hardware**, and the [specification](../specification/voice-transcription.md) states only what the code does, never what a device did.

Unvalidated by manual exercise:

- **Microphone capture.** No recording has been made. Device binding by UID, the hardware tap format, the 1-second first-buffer deadline, the 32-buffer queue depth, and CAF recovery writing are untested against real audio hardware.
- **Speech analysis and assets.** No asset status check, download, reservation, or transcription has been run. Whether the progressive-transcription preset, the format conversion, and the 5-second finalization bound behave as intended in practice is unknown, as is whether the queue depth and finalization bound are the right values.
- **Fn gestures.** The event tap, the 150 ms hold threshold, Fn-Space consumption, the secure-input watchdog, and tap re-enable after a system disable have only been exercised as pure reducers in tests. Whether the default threshold feels right, and whether consuming Fn-Space breaks any expected macOS behavior, is unknown.
- **Bluetooth and AirPods.** The fail-closed name matching has never been run against a real paired headset. Whether AirPods report a usable Core Audio name, whether the connected check is accurate at the moment of selection, and whether switching to a headset microphone degrades transcription are all open.
- **Paste actions.** Synthetic Command-V has not been tried against a real editor. Auto-paste and paste latest now capture process identity and revalidate PID, bundle identity, lifetime, and age before posting, but event posting still cannot prove that an editor inserted the text.
- **Permission prompts.** The launch-silent, contextual request flow for Microphone, Input Monitoring, Accessibility, and any Speech framework authorization has not been walked through on a machine without the grants. The relevant usage-description strings are present, but whether SpeechAnalyzer presents a separate speech-recognition prompt remains unobserved.
- **Recovery in anger.** Reconciliation is well covered by tests over a fake store, but no real interrupted session has been recovered, retried, or deleted.

Known implementation gaps, independent of validation:

- **No settings control for two values.** The Fn hold threshold and maximum session duration are file-only.
- **Auto-paste requires a captured target.** Retries have no trustworthy target, and a live session armed while XMT is frontmost deliberately captures none. In either case the transcript is committed to the clipboard and, when history is enabled, to durable history, without automatic paste; paste latest can subsequently target the application focused when that separate command is invoked.
- **Coverage remains strongest in pure layers.** Trigger/session arbitration now covers cancellation while arming, and device selection, queues, reconciliation, commit ordering, history, and configuration are unit-tested. Capture, the analyzer session, module coordinator effects, and SwiftUI surfaces still lack end-to-end coverage.

Until at least a recording, a transcription, and a paste have been performed by hand, Voice Transcription should be described as implemented, not as shipping. The deferred exercise is recorded as a repeatable [Voice hardware QA checklist](../qa/voice-transcription.md).

## Future Voice history and clients

The menu's five recent previews, `Copy Latest`, `Show All`, and confirmed clear, and the lazily created searchable panel with per-entry copy, paste, delete, and clear, are implemented over the bounded history store and specified in [transcript history surfaces](../specification/voice-transcription.md#transcript-history-surfaces). Paste from those surfaces verifies the captured target before posting and always leaves the transcript on the clipboard when it refuses or fails. None of it has been exercised on hardware: no panel has been opened, no history paste has been observed reaching another application, and the target-verification refusals are covered only by injected unit tests. With history effectively disabled the surfaces are inert and reach no repository, so a disabled history never creates the database; that too is only unit-tested, never observed with a managed disable on a real machine.

The one-slot `last-transcript.txt` cache has been retired as a writer: no commit recreates it, and it survives only as one-time migration input that registration imports and deletes. The `Copy Last Transcript` menu action remains, now serving the in-memory last transcript rather than a file, and duplicates `Copy Latest Transcript` whenever history is enabled; collapsing the two is an open user-interface decision, not a storage gap.

The store behind those surfaces is a serialized SQLite database with a strict, versioned schema, owner-only file permissions, post-migration schema validation, idempotent transactional append-and-prune, immediate pruning when retention is tightened, and a crash-idempotent import of the former one-slot cache; it is specified in [durable history storage](../specification/voice-transcription.md#durable-history-storage) and covered by `XMTTests/TranscriptHistoryStoreTests.swift` and `XMTTests/TranscriptHistoryCommitTests.swift`. Nothing about it has been observed on hardware either: no real transcript has been committed into it, and its behavior under a genuine crash rather than an injected failure is untested. Two hardening limits are known and deliberate: permission narrowing is best effort and is not re-asserted for side files SQLite recreates later in a run, and an incompatible database is refused for the process rather than repaired or renamed, so a user who somehow acquires one has no in-app recovery beyond deleting the file.

A Raycast client is also deferred. It must consume an app-owned, stable JSON boundary designed for external clients rather than reading XMT's cache or any future internal history store directly. Versioning, lifetime, privacy, and write ownership for that boundary must be settled before the client ships.

## Configuration gaps

- **Reload is explicit, not observed.** [Declarative configuration](../architecture/configuration.md#loading-and-reloads) intends file-system observation with coalescing. The implementation reloads at launch, whenever the app becomes active, and on a Settings button. Nothing watches the file, which is the intended design's remaining delta and not a defect in the current behavior.

## Keyboard Customization feasibility

The non-live product layer now includes the [Keyboard settings surface](../specification/keyboard-customization.md), explicit profiles, per-device/per-key editable timings, managed-source resolution, and a pure Hyper/home-row policy compiler. Registration reconciliation, modifier composition, selective gesture updates, stale/duplicate acknowledgements, and bounded output execution have regression coverage. These are configuration/model capabilities, not an operational keyboard backend. The Settings tab explicitly reports unavailable and opens no devices.

Remaining implementation and evidence gates include full HID-interface forwarding preflight, physical acquisition with neutral handover, authenticated live transport, independent watchdog enforcement, Caps/Fn state and LED handling, signing/packaging, and separately authorized external/built-in keyboard trials. A noncooperative fake sink is failure-notified and isolated from concurrent cleanup; this does not prove physical release. Voice remains default-disabled.

The approved T-1 spike is ready to test whether the protected-input architecture in [Keyboard Customization](../architecture/keyboard-customization.md) is feasible. “Approved” selects a direction; it does not assert system-extension entitlement approval, successful installation, seizure release behavior, or working hardware interception.

The gates are sequential and separately authorized:

1. **Build-only / no-live-device stage.** Create only enough spike scaffolding to prove the app, task-scoped seizure owner, HIDDriverKit virtual keyboard, XPC lease, and independent watchdog can compile, sign in the available development environment, and package coherently. Do not open or seize any keyboard and do not activate the design against live input.

   The unsigned code-only subset is complete, not the signed coherent-package gate. Pure tap-hold resolution rejects invalid replacement atomically and bounds timing arithmetic; protected-input ownership binds every readiness acknowledgement to a process session and waits for release acknowledgement; strict policy validation bounds devices, keys, timing, identities, wire size, and protocol roles. A fake transformation runtime proves explicit inventory resolution, output balancing, atomic policy replacement, backoff, and fail-closed release retry without polling. Separate `XMTKeyboardOwner`, `XMTKeyboardWatchdog`, and `XMTVirtualKeyboard` targets compile as universal unsigned products through `XMTKeyboardFeasibility`; the executables exit immediately and the dext declares no `IOKitPersonalities`. No target is embedded in `XMT.app`, and no XPC listener, real seizure backend, monitoring loop, live device enumeration, or HID connection exists. Signing is blocked — the four DriverKit entitlements the design needs are restricted, none has been requested from or granted by Apple, no provisioning profile carrying them exists, and no Developer ID identity is available. Observations are in [Keyboard DriverKit build-only evidence](../qa/keyboard-driverkit-feasibility.md).
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

1. **Voice Transcription.** Implemented and integrated; its behavior is specified in [the Voice Transcription specification](../specification/voice-transcription.md). Audit-driven arming, cancellation, secure-input, paste-target, recovery, Bluetooth-consent, and conversion fixes are now present. Hardware validation listed above remains the release gate. Nothing else should start before a real recording has been made, transcribed, and pasted, because that exercise is the only thing that can tell whether the threshold, queue depth, timeouts, and device rules were chosen sensibly — and because the module holds a microphone and an event tap, which is exactly the kind of thing that should not sit unverified in a resident menu bar app.
2. **Keyboard Customization.** Run the T-1 feasibility gates above: build-only and no-live-device first, then separately authorized external-keyboard and built-in-keyboard tests. The two user-visible capabilities belong to one module but remain independently enabled. Safety evidence, not feature ordering, controls progression.
3. **Menu Bar Management.** Cross-app control is closed as a public-API no-go; unsupported Accessibility/layout manipulation will not be pursued. XMT's own icon behavior remains ordinary shell work if a need arises.

Ordinary modules share the app-process failure domain. Keyboard Customization is the explicit isolated-process/system-extension safety exception; that isolation carries its own feasibility and recovery risks. See [failure domain and isolation](../architecture/app-shell.md#failure-domain-and-isolation).

## Related documentation

- [Product](../PRODUCT.md) — the goals this sequencing serves.
- [Architecture](../architecture/README.md) — the design these gaps are measured against.
- [Specification](../specification/README.md) — what is actually implemented.
