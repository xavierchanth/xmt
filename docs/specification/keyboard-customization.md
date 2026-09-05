# Keyboard Customization configuration

This page specifies the Keyboard settings surface and pure policy compilation in XMT. The app saves requested settings and displays an unavailable backend; these controls do not discover, acquire, or transform a live keyboard. Hardware delivery gates belong to the [roadmap](../roadmap/README.md#keyboard-customization-feasibility).

## Settings and persistence

The Keyboard tab is available independently of the Voice build flag. Hyper Caps and home-row modifiers are independently requested and default off. No keyboard is included by default. Profiles are added by entering a stable ID and known device identity: built-in status, decimal vendor/product IDs, and serial number or location information accepted by the strict identity validator. Adding a profile does not enumerate hardware.

Each profile exposes Hyper hold, home-row hold, and home-row quick-tap milliseconds, plus per-key hold and quick-tap overrides. Hold values accept 1 through 60,000 milliseconds; quick-tap accepts 0 through 60,000, with zero disabling quick-tap. Defaults are 200, 200, and 150 milliseconds respectively. Caps quick-tap is always zero. Reset buttons clear unmanaged local timing overrides. Invalid changes display a configuration diagnostic and preserve the last accepted values.

Preferences are encoded under `keyboardCustomization.settings.v1` in UserDefaults. The shared configuration coordinator validates a proposed change against the freshly read file before persistence and publication. File-managed controls are locked. The UI reports requested behavior only; it never presents a saved preference as active device ownership.

## Configuration file

The optional `keyboardCustomization` section uses the existing version 1 configuration file. For example, with placeholder identity values:

```json
{
  "version": 1,
  "keyboardCustomization": {
    "hyperEnabled": false,
    "homeRowEnabled": false,
    "devices": [{
      "id": "desk-keyboard",
      "identity": {
        "builtIn": false,
        "vendorID": 1234,
        "productID": 5678,
        "serialNumber": "replace-with-real-identity"
      },
      "hyperHoldMs": 200,
      "homeRowHoldMs": 200,
      "homeRowQuickTapMs": 150,
      "keyTiming": { "a": { "holdMs": 220, "quickTapMs": 150 } }
    }]
  }
}
```

File values precede local values and built-in defaults. Device membership is atomic: a supplied file array replaces the local list, and an empty array includes nothing. Local timing supplements a file-selected device only when ID and complete identity match. A file-supplied base timing also governs local per-key timing; local overrides cannot bypass it. Removing the file value exposes the retained local preference again. Unknown physical positions, duplicate or ambiguous identities, and out-of-range timings are rejected even when capabilities are off.

## Compiled behavior

The pure compiler uses physical positions in keyboard usage page `0x07`, not macOS virtual key codes. Caps taps Escape and holds Control-Shift-Option-Command; another key press resolves pending Caps as Hyper immediately. Home-row taps emit their original usage. Holds map A/semicolon to Control, S/L to Shift, D/K to Option, and F/J to Command. Home-row resolution is timing-only; a quick second press after a tap emits the held/repeating letter.

Product policies mark their semantics explicitly. Hyper and conventional physical modifiers make a newly pressed home-row key an ordinary key until release; home-row-origin modifiers can stack. Physical and synthetic modifier ownership is accounted together. Timing changes retain the timing captured by an existing pending gesture. Structural changes cancel affected interpretation without inventing taps and suppress affected held keys until release, preserving unchanged capability state.

## Test-only runtime boundary

The injected transformation runtime serializes output through a bounded queue and rejects further ordinary input on failure. Output stalls and queue age are bounded; failure invokes an independent failure callback. Cancellation cannot force a noncooperative output sink to return, and cleanup does not run concurrently with that sink. Policy identity changes balance formerly routed device state. The version 2 helper wire envelope rejects earlier versions rather than silently downgrading product semantics.

No live Fn transport, Caps Lock reconciliation, physical seizure, or virtual report submission is connected to these settings. Fn-Caps is consequently not an available recovery action in this build. The [architecture](../architecture/keyboard-customization.md) defines the intended live boundary.
