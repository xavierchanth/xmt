# Module model

A module is one coherent macOS behavior change that XMT provides. This page defines what a module is, the boundary rules it must respect, and the intended module inventory with each module's scope and permission boundary. It is target design: naming a module here is not a claim that it exists, and no type, file, or API named here should be assumed to be in the source tree. What exists, what is planned, and in what order is [the roadmap](../roadmap/README.md)'s to say.

## What counts as a module

A module owns a user-visible behavior, its triggers, its settings, and the OS permissions that behavior requires. It is a module — rather than a helper inside another module — when all of the following hold:

- it can be enabled or disabled on its own without changing another module's behavior;
- it has its own permission requirements, or its own trigger vocabulary;
- a user would describe it as a separate thing the app does.

Shared machinery — coordinate conversion, Accessibility element wrappers, shortcut registration, permission plumbing — is not a module. It is shell or shared infrastructure, and it lives outside any module so no module owns another's dependencies.

## Compile-time modularity, not plugins

Modules are compiled into the app. XMT does not load code at runtime, does not define a plugin ABI, and does not support third-party extensions. Modularity here is a source and ownership discipline: clear boundaries, one-directional dependencies on the shell, and the ability to delete a module by removing its directory and its registration entry.

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
| Voice Transcription | Dictate text into the focused input | Microphone, Speech Recognition |
| Keyboard Customization | Remap keys and provide a Hyper-key layer | Input Monitoring, Accessibility |
| Menu Bar Management | Hide and reveal menu bar items | Accessibility |

### Window Mover

Moves the focused window to the next display on a global shortcut, preserving relative geometry and handling native full-screen windows. Its normative behavior is specified in [the Window Mover specification](../specification/window-mover.md); source and tests remain the final authority.

Boundary: this module reads and writes window geometry through Accessibility and does nothing else. Display arrangement, spaces, and window contents are outside its scope.

### Voice Transcription

Intended design: a push-to-talk shortcut starts an on-device speech session, and recognized text is inserted into the focused input. The audio input and the recognition session are acquired when the shortcut begins and released when it ends, so the module holds no microphone resource at rest.

The target design assumes Apple's on-device **SpeechAnalyzer** API for recognition. That is a design intent, not an integration: no XMT code uses it. It also carries a compatibility consequence that has to be settled before adoption. SpeechAnalyzer requires a substantially newer macOS than the app's current `MACOSX_DEPLOYMENT_TARGET` of 14.0 — confirm its exact minimum against Apple's documentation before planning around it — so adopting it means one of three things — raising the deployment target and dropping support for the older macOS versions the app currently runs on, gating the module behind an availability check so it simply does not appear on older systems, or choosing a different recognition API. Nothing here presumes which.

Boundary: this module owns capture, recognition, and insertion of text. It does not own the shortcut system or the permission prompts, which belong to [the shell](app-shell.md).

### Keyboard Customization

Intended design: key remapping and a Hyper-key layer. Remapping through a supported macOS mechanism is preferred to an always-on event tap; an event tap, if used, is a started/stopped resource under the shell's lifecycle rules and is the module's own failure domain.

Home-row modifier behavior is a distinct increment with its own design problem — tap-versus-hold timing — and is kept separate from plain remapping so that the two can be reasoned about, enabled, and disabled independently.

Boundary: this module transforms key events. It does not interpret application context or provide text expansion.

### Menu Bar Management

Intended design: hide, reveal, and reorder menu bar items in place of a separate utility.

The design constraint worth recording here is that macOS exposes no adequate public API for controlling other applications' menu bar items. Any implementation therefore depends on Accessibility manipulation and layout techniques that are not contracts and can change across macOS releases, which means this module's boundary must keep that fragility entirely inside itself: no other module may depend on it, and its failure must not affect the rest of the app. Whether it is attempted at all, and when, is stated in [the roadmap](../roadmap/README.md#sequencing-and-risk).

## Related documentation

- [App shell](app-shell.md) — the host that modules plug into.
- [Specification](../specification/README.md) — normative behavior of implemented modules.
- [Roadmap](../roadmap/README.md) — delivery state, gaps, and ordering.
