# Declarative configuration

This page defines the intended configuration boundary shared by XMT's shell and modules: a versioned, declarative input and deterministic resolution rules. It is target design and does not describe what the app does today; the file's normative behavior is [the configuration specification](../specification/configuration.md), and delivery state remains in the [roadmap](../roadmap/README.md).

## Sources and precedence

Effective settings are resolved from three layers, from lowest to highest precedence:

1. built-in defaults;
2. values persisted by the Settings UI;
3. values explicitly present in the declarative configuration file.

An omitted file value therefore leaves the corresponding persisted value in force; it does not reset it. The same resolver supplies settings to the UI and to modules so that displayed and applied values cannot diverge. The UI may explain that a value is file-controlled, but must not silently rewrite the file.

The file has a required top-level schema version. Readers accept only versions they understand and do not guess at migrations. Device priority is represented as an ordered list, while fallback to the current system-default input is a separate Boolean choice rather than an implicit final list entry. Shortcut values use a serialized data representation at this boundary rather than exposing a shortcut library's storage format as configuration format.

Each module exposes persisted values through its own settings adapter. A shell-owned aggregate composes those partial values into the local snapshot used by resolution and delegates rollback to the adapter that owns the affected storage. The configuration coordinator therefore depends on neither a neighbouring module nor a shortcut library's persistence details.

## Loading and reloads

At launch, absence of the file is a valid state and resolution continues from defaults and persisted settings. A present file is decoded and validated completely before any value is published. An unsupported version, unreadable file, or invalid field leaves the last known-good effective settings in place; on the first invalid launch, that means defaults plus persisted settings.

Reload observes file-system changes rather than polling. Changes are coalesced, parsed off the action path, and published as one complete snapshot. Modules receive the snapshot through shell lifecycle coordination: trigger registrations and action-owned resources are replaced or released deterministically, never partially mutated during decoding. Removing the file is a valid change and returns resolution to defaults plus persisted settings.

No configuration load starts Voice Transcription work by itself. Audio capture, speech analysis, and recovery processing remain action-scoped under the module lifecycle.

## Related documentation

- [Configuration specification](../specification/configuration.md) — the file location, schema, validation, precedence, and reload behavior that are implemented.
- [App shell](app-shell.md) — lifecycle, trigger providers, and publication of effective settings.
- [Module model](modules.md#voice-transcription) — Voice Transcription's target behavior and settings.
- [Roadmap](../roadmap/README.md) — delivery state and integration risks.
