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
    "holdToTalkBindings": [{ "type": "modifierHold", "modifier": "fn" }],
    "toggleRecordingBindings": [{ "type": "fnChord", "key": "space" }],
    "cancelBindings": [{ "type": "fnChord", "key": "escape" }],
    "pasteLatestTranscriptShortcut": { "type": "key", "key": "v", "modifiers": ["control", "command"] },
    "outputMode": "pasteImmediately",
    "history": {
      "enabled": true,
      "retentionDays": 30,
      "maxEntries": 500
    },
    "locale": "system",
    "fnHoldThresholdMs": 150,
    "maxSessionSeconds": 300,
    "inputDevicePriority": [{ "name": "Studio Microphone", "uid": "BuiltInMicrophoneDevice" }],
    "fallbackToSystemDefault": true
  }
}
```

Field meanings are owned by the modules: [Voice Transcription](voice-transcription.md) for the `voice` section, [Window Mover](window-mover.md) for `windowMover`.

### Shortcut values

A shortcut is one of four shapes, distinguished by `type`:

- `key` — a `key` name plus an optional `modifiers` array drawn from `command`, `control`, `option`, and `shift`. Key names cover digits, letters, `f1` through `f20`, and named keys such as `space`, `return`, `tab`, `escape`, `delete`, `forwarddelete`, the arrows, `home`, `end`, `pageup`, `pagedown`, and the punctuation keys. Names are case-insensitive.
- `modifierHold` — the modifier name `fn` or its alias `function`. Only Voice hold-to-talk accepts this shape, and only for Fn.
- `fnChord` — a supported `key` name combined with the physical Fn modifier. Voice actions accept this shape.
- `unbound` — the legacy scalar representation of an absent Voice binding.

The canonical `holdToTalkBindings`, `toggleRecordingBindings`, and `cancelBindings` fields are ordered arrays of these values. An empty array explicitly unbinds that action and does not fall through to local or built-in defaults. For one release, the singular `holdToTalkShortcut`, `toggleRecordingShortcut`, and `cancelShortcut` fields (and the older `shortcut` hold alias) decode as one-item arrays; encoding emits arrays only.

When `type` is omitted, a document containing `modifier` is read as a modifier hold and anything else as a key shortcut. A modifier hold is deliberately not representable as a key shortcut with optional bits.

### Validation

Decoding is all-or-nothing: a document is decoded, version-checked, and fully validated before any value is published. Diagnostics distinguish an unreadable file, malformed JSON with the failing coding path, an unsupported version, and an invalid value with its path and reason. The validated constraints are:

- `windowMover.shortcut` MUST be a key shortcut — a modifier hold is rejected for Window Mover — and MUST convert to a real key and modifier set.
- Each Voice action array accepts Fn chords or ordinary key chords; hold-to-talk additionally accepts an Fn modifier hold. Hold and Toggle standard key chords require at least one of Control, Option, or Command. Bare and Shift-only chords are rejected because their always-ready registration could intercept normal typing; Shift may additionally accompany one of those safe modifiers. Cancel accepts any key chord, including bare Escape, because it is registered only during arming or recording. Fn modifier-only is rejected for toggle/cancel. Exact duplicates within an action and conflicts across actions, Window Mover, or Paste Latest reject the entire candidate. Bare Fn hold intentionally remains compatible with Fn chords.
- `voice.pasteLatestTranscriptShortcut` MUST be a key shortcut that converts to a real key and modifier set; modifier holds are rejected.
- `voice.history.retentionDays` and `voice.history.maxEntries` MUST each be at least 1.
- `voice.keepLastTranscript` is a decode-only compatibility alias for `voice.history.enabled` for one release. Supplying both keys rejects the complete candidate, even when their Boolean values agree; encoding emits only the canonical `history` object.
- `voice.locale` MUST NOT be blank.
- `voice.fnHoldThresholdMs` MUST be between 50 and 500.
- `voice.maxSessionSeconds` MUST be between 1 and 3600.
- Each `voice.inputDevicePriority` entry MUST have a non-blank `name`, MUST NOT have a blank `uid` when `uid` is present, and MUST NOT duplicate an earlier entry. Duplication is compared case-insensitively and whitespace-trimmed, by `uid` when present and by `name` otherwise.

An empty `inputDevicePriority` array is a valid explicit value and is distinct from omitting the key.

## Precedence

Effective settings resolve per key, from lowest to highest precedence:

1. **Built-in defaults.** Window Mover enabled with Option-Space; Voice enabled with bare-Fn hold, Fn-Space toggle, and Fn-Escape cancel; paste latest transcript with Control-Command-V; output mode `pasteImmediately`; transcript history enabled with 30 retention days and at most 500 entries; locale `system`; Fn hold threshold 150 ms; maximum session 300 seconds; empty device priority; system-default fallback on.
2. **Persisted local values** written by the settings UI.
3. **Values explicitly present in the configuration file.**

Resolution is per key, not per section: omitting a key leaves the persisted value in force rather than resetting it, and removing the file returns every key to defaults plus persisted values. Each resolved value carries its source, so a change of source alone counts as a change. `XMTTests/ConfigTests.swift` covers the precedence matrix, per-key independence, and removal.

All Voice bindings, Window Mover, and paste-latest shortcuts may be managed by the file. For each, XMT preserves the prior recorder value when management begins and restores it when the key is removed. The three Voice action bindings are independent and each accepts `{ "type": "unbound" }`; an explicit unbound local or managed value never falls through to a default. Effective duplicate bindings across Voice, Window Mover, and Paste Latest reject the complete snapshot before handlers change.

The former local `voice.keepLastTranscript` preference is migrated once to `voice.history.enabled` before defaults are registered. Existing canonical data wins if both keys exist, the legacy key is removed, and repeating the migration changes nothing.

## Managed values

A value supplied by the configuration file is **managed**. Managed values are applied immediately and are not written back to persisted settings, so removing the file restores what the user had configured.

Voice settings provides a confirmed **Restore Default Bindings** action scoped only to the three Voice binding lists. Confirmation validates the complete candidate and then publishes Hold to Talk with Fn, Toggle Recording with Fn-Space, and Cancel with Fn-Escape as one effective-settings update; every other app setting remains unchanged. The action is disabled if any one of the three lists is configuration-managed. A raced management or validation failure preserves all three customized lists and publishes no partial effective result. This all-or-nothing guarantee describes validation and in-process settings publication, not crash-transactional persistence: the underlying `UserDefaults` values are written separately and an interruption during those writes can leave partially updated preferences for the next launch.

The settings UI disables the control for a managed value rather than presenting a write that would not take effect: the Voice enable toggle, all three Voice binding recorders, paste-latest shortcut recorder, output mode, each of the history enabled/retention/maximum controls, locale, the device priority list and its add action, and the system-default fallback toggle; and in Window Mover, the enable toggle and the shortcut recorder. Managed ordinary shortcuts are pushed into the shortcut store directly.

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
