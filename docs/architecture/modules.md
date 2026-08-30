# Module model

A module is one coherent macOS behavior change that XMT provides. This page defines what a module is, the boundary rules it must respect, and the intended module inventory with each module's scope and permission boundary. It is target design: naming a module here is not a claim that it exists, and no type, file, or API named here should be assumed to be in the source tree. What exists, what is planned, and in what order is [the roadmap](../roadmap/README.md)'s to say.

## What counts as a module

A module owns a user-visible behavior, its triggers, its settings, and the OS permissions that behavior requires. It is a module — rather than a helper inside another module — when all of the following hold:

- it can be enabled or disabled on its own without changing another module's behavior;
- it has its own permission requirements, or its own trigger vocabulary;
- a user would describe it as a separate thing the app does.

Shared machinery — coordinate conversion, Accessibility element wrappers, shortcut registration, permission plumbing — is not a module. It is shell or shared infrastructure, and it lives outside any module so no module owns another's dependencies.

## Compile-time modularity, not plugins

Modules are built into the product. XMT does not load code at runtime, does not define a plugin ABI, and does not support third-party extensions. Ordinarily module logic is compiled into the app process. Keyboard Customization has one explicit safety exception: its built-in module coordinates isolated task-scoped and system-extension components required for protected keyboard IO. Those components are not plugins and do not create another app or user-visible module. Modularity remains a source and ownership discipline: clear boundaries, one-directional dependencies on the shell, and the ability to delete a module and its registered helper components without disturbing the others.

This is deliberate. A dynamic plugin system would add a loading mechanism, a stability contract, and a trust boundary to solve a problem a single-user app does not have. The benefit sought from modularity — being able to reason about, disable, or remove one behavior without disturbing the others — is fully available at compile time.

The practical test: removing a module's source directory and its registration should leave a building app with every other module intact.

## Module contract

Each module provides to the shell:

- **Identity** — a stable name used in settings and shortcut storage.
- **Declared permissions** — the macOS grants it needs, surfaced and re-requestable in Settings. See [permission gating](app-shell.md#permission-gating).
- **Triggers** — the shortcuts or events that invoke it, registered at start and removed at stop.
- **Lifecycle handlers** — start, stop, and teardown, following [module lifecycle](app-shell.md#module-lifecycle).
- **Settings content** — its own section of the settings window; never its own window.

Each module must:

- perform no work while idle;
- treat OS calls as failure-prone and return without action on an unexpected result;
- run at most one action at a time and drop, not queue, overlapping triggers;
- avoid mutable state shared with another module.

## Module inventory

The intended modules, their scope, and their permission boundary. This table states design boundaries only; for delivery state and ordering see [the roadmap](../roadmap/README.md).

| Module | Scope | Declared permissions |
|---|---|---|
| Window Mover | Move the focused window to the next display | Accessibility |
| Voice Transcription | Dictate text, retain the last transcript, and optionally paste it into the focused input | Microphone; Input Monitoring for Fn gestures; Accessibility when auto-paste is enabled |
| Keyboard Customization | Hyper Caps and home-row modifiers, independently enabled and explicitly scoped by device | Input Monitoring and approval/activation required by macOS for its isolated HID components |
| Menu Bar Management | Control XMT's own menu bar item only; cross-app management is a public-API no-go | None beyond shell needs |

### Window Mover

Moves the focused window to the next display on a global shortcut, preserving relative geometry and handling native full-screen windows. Its normative behavior is specified in [the Window Mover specification](../specification/window-mover.md); source and tests remain the final authority.

Boundary: this module reads and writes window geometry through Accessibility and does nothing else. Display arrangement, spaces, and window contents are outside its scope.

### Voice Transcription

This section states target design. For the behavior the module actually implements, read [the Voice Transcription specification](../specification/voice-transcription.md); source and tests remain the final authority.

The primary gestures are **hold Fn** for push-to-talk and **Fn-Space** to toggle recording. A configurable shortcut provider and a dedicated Fn-event provider feed one shell-owned arbitrator, as described in [trigger providers](app-shell.md#trigger-providers). Starting either gesture creates one session; ending push-to-talk or toggling again closes capture and allows recognition to finish. Conflicting or overlapping transitions do not create concurrent sessions.

Each session selects an input from the user's explicit ordered device list. Whether selection may fall back to the current system-default input is a separate setting, not an implied final list entry. Capture and Apple's on-device **SpeechAnalyzer** with **SpeechTranscriber** are action-scoped and released after completion. The app targets macOS 26 directly for these APIs rather than carrying an older-system availability branch.

Audio is held in a bounded in-memory queue during normal processing. Temporary recovery audio may be written only for an interrupted or not-yet-committed session, with enough session state to reconcile it after relaunch; successful or deliberately discarded sessions remove it. Recovery is bounded, private to the app, and not a recordings library. Reconciliation must be idempotent so one pending session cannot commit twice.

A completed result replaces the module's last transcript. Automatic paste is optional: when enabled, commit preserves the transcript first and then asks a separate paste service to insert it into the focused input. A paste failure does not discard the transcript. When auto-paste is disabled, no Accessibility insertion is attempted.

The module declares Microphone permission for capture and Input Monitoring for Fn observation. Accessibility is required only for enabled auto-paste. XMT also includes a speech-recognition usage description defensively; whether SpeechAnalyzer presents that authorization flow remains a [hardware-validation question](../roadmap/README.md#voice-transcription-validation-gaps). Permission acquisition and presentation remain shell responsibilities.

Voice settings, including triggers, ordered devices, separate system-default fallback, recovery policy, transcript handling, and auto-paste, participate in the shared [versioned declarative configuration](configuration.md) and its precedence rules.

Boundary: this module owns device selection, capture, recognition, recovery reconciliation, transcript commit, and optional paste. It does not own trigger registration, configuration loading, or permission prompts, which belong to [the shell](app-shell.md).

### Keyboard Customization

Keyboard Customization is one user-visible module whose Hyper Caps and home-row modifier capabilities can be enabled independently. Its protected-input work is the sole exception to the normal in-app process shape. See the [Keyboard Customization architecture](keyboard-customization.md) for device scoping, timing resolution, key mappings, Caps Lock recovery, and the isolated seizure-owner/virtual-keyboard safety design.

Boundary: this module transforms key events from explicitly included keyboards. It does not interpret application context, provide text expansion, or alter excluded firmware-managed keyboards.

### Menu Bar Management

Cross-application Menu Bar Management is a no-go: macOS has no adequate public API for hiding, revealing, or reordering other applications' items, and XMT will not build the feature from unsupported Accessibility/layout manipulation. Behavior of XMT's own icon remains app-shell territory rather than a module.

## Related documentation

- [App shell](app-shell.md) — the host that coordinates built-in modules.
- [Specification](../specification/README.md) — normative behavior of implemented modules.
- [Roadmap](../roadmap/README.md) — delivery state, gaps, and ordering.
