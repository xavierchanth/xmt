# Configuration specification

XMT resolves its settings from three layers and accepts an optional declarative JSON file as the highest-precedence one. This page specifies the implemented behavior: where the file lives, what it may contain, how values are validated, how the three layers resolve, what a file-supplied value does to the settings UI, and when a reload happens. The intended end state of this boundary — including the file watching that is not implemented — is [declarative configuration](../architecture/configuration.md).

This is a specification of released behavior. Every claim was read from `XMT/Configuration/`, `XMT/VoiceTranscription/VoiceTranscriptionModule.swift`, `XMT/WindowManagement/WindowMoverModule.swift`, and `XMT/Settings/`, and from the tests in `XMTTests/ConfigTests.swift`. Where this page and the source disagree, the source is correct.

Normative language: **MUST**, **MUST NOT**, and **MAY** in this document describe invariants the current implementation upholds, not requirements on future work.

## File location

The file path is `xmt/config.json` under a configuration base directory:

- `$XDG_CONFIG_HOME/xmt/config.json` when `XDG_CONFIG_HOME` is set to an absolute path;
- otherwise `~/.config/xmt/config.json`.

A relative or empty `XDG_CONFIG_HOME` is ignored in favour of `~/.config`. The file is optional: its absence is a valid state, not a diagnostic, and resolution continues from the lower layers.

## Schema

The document is a JSON object with a required integer `version`. The only supported version is **1**; any other value is rejected. Both section objects are optional, and unknown keys anywhere are ignored, so a partial file is valid.

```json
{
  "version": 1,
  "windowMover": {
    "enabled": true,
    "shortcut": { "type": "key", "key": "space", "modifiers": ["option"] }
  },
  "voice": {
    "enabled": true,
    "shortcut": { "type": "modifierHold", "modifier": "fn" },
    "autoPaste": true,
    "keepLastTranscript": true,
    "locale": "en-US",
    "fnHoldThresholdMs": 150,
    "maxSessionSeconds": 300,
    "inputDevicePriority": [{ "name": "Studio Microphone", "uid": "BuiltInMicrophoneDevice" }],
    "fallbackToSystemDefault": true
  }
}
```

Field meanings are owned by the modules: [Voice Transcription](voice-transcription.md) for the `voice` section, [Window Mover](window-mover.md) for `windowMover`.

### Shortcut values

A shortcut is one of two shapes, distinguished by `type`:

- `key` — a `key` name plus an optional `modifiers` array drawn from `command`, `control`, `option`, and `shift`. Key names cover digits, letters, `f1` through `f20`, and named keys such as `space`, `return`, `tab`, `escape`, `delete`, `forwarddelete`, the arrows, `home`, `end`, `pageup`, `pagedown`, and the punctuation keys. Names are case-insensitive.
- `modifierHold` — the modifier name `fn` or its alias `function`. Voice Transcription v1 is the only module accepting this shape.

When `type` is omitted, a document containing `modifier` is read as a modifier hold and anything else as a key shortcut. A modifier hold is deliberately not representable as a key shortcut with optional bits.

### Validation

Decoding is all-or-nothing: a document is decoded, version-checked, and fully validated before any value is published. Diagnostics distinguish an unreadable file, malformed JSON with the failing coding path, an unsupported version, and an invalid value with its path and reason. The validated constraints are:

- `windowMover.shortcut` MUST be a key shortcut — a modifier hold is rejected for Window Mover — and MUST convert to a real key and modifier set.
- `voice.shortcut` MUST be a modifier hold naming `fn` or `function`; key shortcuts and other modifiers are rejected.
- `voice.locale` MUST NOT be blank.
- `voice.fnHoldThresholdMs` MUST be between 50 and 500.
- `voice.maxSessionSeconds` MUST be between 1 and 3600.
- Each `voice.inputDevicePriority` entry MUST have a non-blank `name`, MUST NOT have a blank `uid` when `uid` is present, and MUST NOT duplicate an earlier entry. Duplication is compared case-insensitively and whitespace-trimmed, by `uid` when present and by `name` otherwise.

An empty `inputDevicePriority` array is a valid explicit value and is distinct from omitting the key.

## Precedence

Effective settings resolve per key, from lowest to highest precedence:

1. **Built-in defaults.** Window Mover enabled with Option-Space; Voice enabled with Fn gestures; auto-paste on; keep last transcript on; locale `en-US`; Fn hold threshold 150 ms; maximum session 300 seconds; empty device priority; system-default fallback on.
2. **Persisted local values** written by the settings UI.
3. **Values explicitly present in the configuration file.**

Resolution is per key, not per section: omitting a key leaves the persisted value in force rather than resetting it, and removing the file returns every key to defaults plus persisted values. Each resolved value carries its source, so a change of source alone counts as a change. `XMTTests/ConfigTests.swift` covers the precedence matrix, per-key independence, and removal.

The Window Mover shortcut may be managed by the file. XMT preserves the prior recorder value when management begins and restores it when the key is removed. Voice Transcription v1 accepts only an Fn modifier-hold value for `voice.shortcut`; other trigger shapes are rejected atomically because the implemented gesture pair is fixed to hold-Fn and Fn-Space.

## Managed values

A value supplied by the configuration file is **managed**. Managed values are applied immediately and are not written back to persisted settings, so removing the file restores what the user had configured.

The settings UI disables the control for a managed value rather than presenting a write that would not take effect: the Voice enable toggle, auto-paste, keep last transcript, locale, the device priority list and its add action, and the system-default fallback toggle; and in Window Mover, the enable toggle and the shortcut recorder. Managed Window Mover shortcuts are pushed into the shortcut store directly.

Applying a snapshot also applies module lifecycle: a Voice module that resolves to enabled recovers from any degraded state and starts observing, and one that resolves to disabled performs a full stop.

## Loading and reload

Loading is explicit and event-driven; nothing watches the file and nothing polls it. A load happens:

- once at launch, when the Voice module registers;
- whenever the app becomes active, which is the practical way an edited file takes effect;
- when `Reload Configuration` is pressed in Voice settings.

Reloads are serialized: a reload started while another is publishing waits for it, including its asynchronous apply callbacks, so two snapshots cannot interleave. Publication delivers one complete snapshot along with the set of keys whose resolved value or source changed.

A failed load leaves the previously published effective settings in force and records a diagnostic, which Voice settings shows next to the reload button. A subsequent successful load clears it. A missing file is not a failure.

Configuration loading never starts a recording, acquires a microphone, or begins speech analysis. Those remain gesture-scoped.

## Related documentation

- [Voice Transcription](voice-transcription.md) — the behavior most of these settings govern.
- [Window Mover](window-mover.md) — the enabled state and shortcut in the `windowMover` section.
- [Declarative configuration](../architecture/configuration.md) — the intended boundary, including reload behavior that is not yet implemented.
- [Roadmap](../roadmap/README.md#configuration-gaps) — the differences between that intent and what runs.
