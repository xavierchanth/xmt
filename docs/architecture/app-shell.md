# App shell

The app shell is the single user-visible app and UI that coordinates every XMT module: the menu bar presence, the settings window, permission handling, module lifecycle, and the resource posture the product promises. This page states the intended design and the boundaries it sets. It is not a description of shipped code, and it does not say which parts of the shell exist — [the roadmap](../roadmap/README.md) owns that.

## Shape

XMT is one `LSUIElement` application with a SwiftUI settings surface. It has no Dock icon, one AppKit `NSStatusItem`, and one reusable settings window that is presented at launch and whenever the app is reopened. The application delegate strongly owns the status-item controller for the process lifetime; closing Settings does not release it or terminate XMT. Ordinary modules run inside this process and share its main actor. Keyboard Customization is the explicit safety exception: the app coordinates its isolated seizure owner, HIDDriverKit system extension, XPC lease, and independent watchdog. They are built-in implementation components, not plugins or additional apps; their target design is in [Keyboard Customization architecture](keyboard-customization.md#protected-input-architecture).

The shell owns exactly four things:

- **Presence** — the menu bar item and its menu.
- **Settings** — the tabbed settings window and its lifecycle.
- **Permissions** — acquisition, status, and re-request flows for the macOS permissions modules depend on.
- **Module lifecycle** — deciding when each module starts, stops, and releases resources.

Everything else belongs to a module. The shell must not encode a module's domain logic, and a module must not reach around the shell to install its own menu bar item or permission prompt.

## Dependency direction

Modules depend on the shell. The shell does not depend on any specific module beyond a registration list, and modules do not depend on each other. A module that needs a capability another module also needs takes it from shared infrastructure rather than from its neighbour, so removing a module cannot break an unrelated one.

## Permission gating

Every module declares the macOS permissions it requires. The shell treats permission as a gate at three points:

1. **At registration.** A module whose permissions are not granted still registers, but starts in an inert state.
2. **At activation.** A module's shortcut or trigger checks the live permission state at the moment it fires rather than trusting a value cached at launch, because the user can revoke a grant at any time.
3. **At the settings surface.** Each module's permission status is visible and re-requestable from Settings.

When a gated action fires without permission, the module reports the denial through the shell rather than presenting its own alert, and the shell shows the reminder at most once per denied state. The reminder unsuppresses when the permission state is observed to have changed, which is checked when the app becomes active. For the normative form of this gate as it applies to a shipping module, see [the Window Mover specification](../specification/window-mover.md#accessibility-permission-gate).

Permissions are not shared for convenience. A module may only use a grant it declared; Accessibility being available because Window Mover needs it does not entitle another module to use it.

## Module lifecycle

The shell drives modules through four transitions:

- **Register** — the module is known to the shell, contributes settings and shortcut names, and holds no OS resources.
- **Start** — the module installs its triggers and acquires the resources it needs. Started is the only state in which a module may hold an audio tap, event tap, observer, or timer.
- **Stop** — the module removes its triggers and returns to registered.
- **Teardown** — on stop and on app termination, every acquired resource is released explicitly: event taps uninstalled, audio and speech sessions ended, notification observers removed, timers invalidated, and background tasks cancelled.

Stop must be idempotent, and teardown must not depend on process exit to reclaim anything. A module that cannot release a resource deterministically is not ready to be started by default.

Disabling a module in Settings performs a real stop, not a flag check inside a still-running trigger.

## Failure domain and isolation

For ordinary modules, one app process means one crash takes everything in that process down. XMT accepts that trade (see [why one app](../PRODUCT.md#why-one-app-instead-of-several)) and mitigates it in process. Keyboard Customization alone adds process/system-extension isolation because seizure recovery is safety-critical:

- A module's trigger handler contains its own failures. A module that cannot complete an action returns without action; it does not terminate the app, and it does not leave the shell in a state that blocks other modules.
- Actions are single-flight per module: a trigger that fires while that module's action is in flight is dropped rather than queued, so a stuck action cannot accumulate work.
- Modules do not share mutable state. Cross-module coupling would turn one module's bug into another's.
- The shell survives a module that fails to start. A failed start leaves that module registered and inert.
- OS-boundary calls — Accessibility, event taps, speech — are treated as failure-prone by default. Absent results are handled as ordinary outcomes, not as programmer errors that trap.

One risk remains for ordinary in-process modules: an unrecoverable fault ends the app process for all of them. Keyboard Customization's isolated components reduce coupling but do not justify any guarantee about seizure release or recovery time. Which modules carry that risk, and in what order they are attempted, is [the roadmap](../roadmap/README.md#sequencing-and-risk)'s to state.

## Resource posture

The commitment is behavioral, not numeric. XMT does not publish a memory or CPU budget and the observations in [the product page](../PRODUCT.md#rough-resource-observations) are not targets.

The rules the shell follows:

- **No idle work.** With no trigger firing, XMT does no polling, no periodic timers, and no background scanning. The native menu refreshes from published state changes and immediately before opening. Idle cost is the cost of a registered shortcut and a menu bar item.
- **Nothing acquired before it is needed.** Modules acquire OS resources at start, not at registration, and heavyweight OS sessions are acquired per action where the API allows it.
- **The recovery UI is bounded.** XMT creates and presents one reusable Settings window at launch so a clipped status item cannot make the app unreachable. Closing it hides the retained AppKit window and SwiftUI host without terminating the accessory app; reopening XMT from Finder presents that same window rather than accumulating windows. macOS can still clip XMT when physical menu-bar space is exhausted (including around a notch). XMT uses only its own public `NSStatusItem`; it cannot control notch allocation or move/remove another application's items.
- **Deterministic release.** Everything acquired at start is released at stop, per [module lifecycle](#module-lifecycle).

These rules explain why resource use stays small. They do not promise a number.

## Trigger providers

The shell coordinates two trigger providers behind one event vocabulary. The shortcut provider owns ordinary configurable global shortcuts. The Fn provider observes the Function key transitions needed for hold-Fn push-to-talk and the Fn-Space toggle without pretending those gestures are ordinary shortcut-library bindings. Providers acquire and release their registrations together with the consuming module and publish events to an arbitrator; neither starts module work directly. Arbitration suppresses duplicate or contradictory transitions and preserves the single-flight rule.

The active Fn observer is an Input Monitoring and Accessibility boundary because it consumes Fn-Space. Voice Transcription declares both permissions in addition to capture permission; observing Fn must not grant the module broader keyboard-remapping ownership. Configurable alternatives remain with the shortcut provider, and the declarative representation of those alternatives remains independent of the shortcut library's private storage.

## Configuration resolution

The shell owns loading and resolving the versioned declarative configuration because precedence must be consistent across modules. Built-in defaults are overlaid by persisted Settings values and then by values explicitly present in the file. A file is validated as a whole and published atomically; invalid input leaves the last known-good effective snapshot active. Missing files and removed files are valid and resolve from defaults plus persisted values.

Reloading is event-driven rather than polled and cannot itself activate a module action. The full rules, including version rejection and file-controlled UI values, are defined in [declarative configuration](configuration.md).

## Settings surface

Settings is one window with one tab per concern, built lazily and shared across modules. A module contributes its own settings content and its permission status row; it does not open its own window. Shortcut recording is centralized so that shortcut names, defaults, and conflicts are visible in one place. Settings displays effective values from the shared resolver and identifies values overridden by declarative configuration rather than presenting a write as effective when it is not.

## Related documentation

- [Module model](modules.md) — what a module is and what it must provide to the shell.
- [Declarative configuration](configuration.md) — source precedence and load/reload semantics.
- [Window Mover specification](../specification/window-mover.md) — normative behavior of a module running inside this shell.
- [Voice Transcription specification](../specification/voice-transcription.md) — normative behavior of the module that exercises the Fn trigger provider and per-action resources.
- [Roadmap](../roadmap/README.md) — which parts of this shell exist and which are outstanding.

### Nonactivating action overlay

The shell may own one lazily created, reusable AppKit panel for action-scoped status and controls. Modules supply semantic presentation state; the panel remains nonactivating, exposes native accessible controls, and is hidden on completion or disable. Presentation is event-driven. An elapsed timer is permitted only while an action is recording, never while hidden or idle.
