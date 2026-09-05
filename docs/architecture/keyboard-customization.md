# Keyboard Customization architecture

This page defines the target design for XMT's Keyboard Customization module. It does not claim that the module or any named component exists; delivery state and authorization gates belong to the [roadmap](../roadmap/README.md#keyboard-customization-feasibility).

## User-visible capability

Keyboard Customization is one module and one settings surface with two independently enabled capabilities:

- **Hyper Caps:** tapping the physical Caps position emits Escape; holding it forms Hyper (Control-Shift-Option-Command).
- **Home-row modifiers:** tapping the keys emits their ordinary characters, while holding maps A and semicolon to Control, S and L to Shift, D and K to Option, and F and J to Command.

Either capability can be stopped without leaving the other active. Fn-Caps provides recovery access to Caps Lock. The module does not intercept input at login, at the FileVault pre-boot screen, or anywhere else before the user's XMT session is running.

## Device scope

Configuration explicitly includes or excludes keyboards by stable device identity. Unlisted devices are not implicitly included. In particular, keyboards whose behavior is managed in firmware remain excluded and their events pass through untouched.

Scope is enforced before key-state interpretation, not merely when emitting output. Device arrival, removal, and identity ambiguity fail closed: no event from a device is transformed until it resolves to an included device.

## Event resolution and timing

Home-row resolution is timing-only; it does not use application context, words, or predictions. Caps additionally resolves as Hyper when another key is pressed, so Hyper shortcuts need not wait for the threshold. Hold and quick-tap timing is configurable per device and may be overridden per key. Caps quick-tap stays disabled so a recent Escape does not suppress a Hyper gesture.

Hyper or a conventional physical modifier makes newly pressed home-row keys ordinary shortcut keys, with that interpretation fixed until release. Home-row-generated modifiers can stack. Physical and generated modifiers share output ownership, preserving held modifiers through either release order. Deferred taps retain event ordering relative to physical modifier transitions.

Input events become per-device key-state transitions. The resolver applies the effective timing policy, emits a resolved logical action, and only then sends virtual-keyboard output. Timing updates preserve the policy captured by an existing gesture; structural updates cancel affected state without inventing a tap, and unchanged capability ownership remains intact. Device removal, lease loss, or teardown cancels unresolved state without inventing a tap.

Caps Lock state is reconciled from keyboard events and system state changes. Reconciliation is event-driven, not polling. If observed Caps Lock state becomes stale or disagrees with the intended state after recovery or reconnection, the next relevant state event schedules an idempotent correction.

## Protected input architecture

Capturing and replacing physical keyboard input is a narrow safety exception to XMT's ordinary in-process module model:

1. A task-scoped IOHID seizure owner opens only explicitly included devices. Apple's keyboard driver remains attached; XMT does not detach or replace it.
2. The owner forwards resolved output through a HIDDriverKit virtual keyboard.
3. The app grants work through an XPC lease. Losing or revoking the lease causes the seizure owner to tear down its task-scoped ownership.
4. An independent watchdog observes lease and owner health and can trigger teardown without depending on the app process.

The control contract is versioned and bounded. Session, lease, output, watchdog, policy-revision, and acquisition-attempt identities travel with every asynchronous acknowledgement that can affect ownership; a delayed message from an earlier process lifetime is inert. Wire DTOs are decoded and validated once at the receiving boundary before strict policy reaches the resolver. Raw physical key events stay inside the seizure owner and are never forwarded to the app or watchdog.

Process termination is expected to release an IOHID seizure, but the design makes no guarantee and claims no release-time bound. Explicit teardown, lease loss, and the independent watchdog are all required rather than relying on termination behavior.

The system extension is isolated implementation machinery for this one built-in module. It is not a plugin, does not create a second app or settings experience, and cannot own arbitrary modules. Direct DriverKit-extension ownership of the built-in keyboard is rejected: the extension supplies the virtual output device, while task-scoped IOHID ownership remains outside the dext. XMT never attempts login-window or FileVault interception.

## Configuration and boundaries

The shared declarative configuration represents capability enablement, explicit device inclusion/exclusion, and per-device/per-key timing overrides. Validation is atomic; invalid or ambiguous device policy leaves the last known-good policy active and does not broaden scope.

The module owns physical-key transformation, state resolution, Caps Lock reconciliation, the XPC lease, and coordination of its isolated helper components. The shell owns the single settings surface and user-visible lifecycle. The module does not interpret application context, expand text, control pointer behavior, or manage other applications' menu bar items.

Keyboard Customization is below, and separate from, the shell's semantic input-routing boundary. It never registers a Window Mover or Voice action and never calls those modules. Resolved virtual-keyboard output rejoins the normal macOS input stream; shared shortcut and Fn providers may then recognize it exactly as they recognize output from any other keyboard. This one-way composition avoids a special cross-module path and keeps seizure ownership out of ordinary trigger infrastructure.

## Related documentation

- [Module model](modules.md) — the built-in module boundary and its process-isolation exception.
- [App shell](app-shell.md) — shell ownership and safety boundaries.
- [Roadmap](../roadmap/README.md#keyboard-customization-feasibility) — feasibility state and test authorization gates.
