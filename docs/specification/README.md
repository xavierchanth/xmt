# XMT specification

This area holds normative behavior specifications for XMT modules that are **implemented**. Unlike [architecture](../architecture/README.md), nothing here is aspirational: every statement describes behavior that the current source produces, and a mismatch between a page here and the code is a documentation defect.

## Authority

Source under `XMT/` and tests under `XMTTests/` are the final authority on exact released behavior. These pages exist to make that behavior readable and to record the intent behind decisions that the code does not explain, such as tolerances and correction passes. Specification pages declare normative language explicitly where they use it.

Planned modules have no page here. They are described as target design under [architecture](../architecture/modules.md#module-inventory) and tracked in [the roadmap](../roadmap/README.md).

## Pages

- [Keyboard Customization configuration](keyboard-customization.md) — the editable profile/timing surface, managed configuration, and pure compiler; no live keyboard interception.

- [Window Mover](window-mover.md) — the shortcut, permission gate, screen selection, geometry mapping, reconciliation, and full-screen handling of the window module.
- [Voice Transcription](voice-transcription.md) — the platform floor, module lifecycle, Fn gestures and arbitration, permissions, speech assets, device selection, capture and recovery, transcript commit, and the menu and settings surfaces.
- [Configuration](configuration.md) — the declarative file's location, schema, validation, three-layer precedence, managed values, and reload behavior shared by both modules.

## Related documentation

- [Architecture](../architecture/README.md) — intended structure, including modules that do not exist yet.
- [Roadmap](../roadmap/README.md) — gaps between the two.
