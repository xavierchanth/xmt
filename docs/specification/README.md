# XMT specification

This area holds normative behavior specifications for XMT modules that are **implemented**. Unlike [architecture](../architecture/README.md), nothing here is aspirational: every statement describes behavior that the current source produces, and a mismatch between a page here and the code is a documentation defect.

## Authority

Source under `Swapper/` and tests under `SwapperTests/` are the final authority on exact released behavior. These pages exist to make that behavior readable and to record the intent behind decisions that the code does not explain, such as tolerances and correction passes. Specification pages declare normative language explicitly where they use it.

Planned modules have no page here. They are described as target design under [architecture](../architecture/modules.md#module-inventory) and tracked in [the roadmap](../roadmap/README.md).

## Pages

- [Window Swapper](window-swapper.md) — the shortcut, permission gate, screen selection, geometry mapping, reconciliation, and full-screen handling of the only implemented module.

## Related documentation

- [Architecture](../architecture/README.md) — intended structure, including modules that do not exist yet.
- [Roadmap](../roadmap/README.md) — gaps between the two.
