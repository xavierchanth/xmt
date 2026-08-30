# XMT architecture

This area describes the **intended** structure of XMT — Xavier's macOS Tweaks: the app shell that every module shares, and the module model that governs how capabilities are added. It is future-first design, not a report on what is built.

## How to read these pages

Architecture pages describe the target design. A module appearing here is not a claim that it exists, that its types are present in the source tree, or that any API named here is callable. Which modules are built and which are not is recorded in one place only, [the roadmap](../roadmap/README.md); for the normative behavior of anything that has shipped, read [the specification](../specification/README.md).

Where architecture and released behavior differ, the source under `XMT/` is correct and the architecture page describes where the code is headed.

## Pages

- [App shell](app-shell.md) — the single user-visible host: lifecycle, permission gating, settings surface, failure isolation, and the explicit keyboard-safety process exception.
- [Module model](modules.md) — what a module is, the compile-time modularity rule, the module contract, and the planned module inventory.
- [Declarative configuration](configuration.md) — versioning, precedence, validation, and atomic load/reload semantics.
- [Keyboard Customization](keyboard-customization.md) — device-scoped Hyper Caps and home-row resolution plus the protected-input safety architecture.

## Related documentation

- [Product](../PRODUCT.md) — the goals this architecture serves.
- [Specification](../specification/README.md) — normative behavior of implemented modules.
- [Roadmap](../roadmap/README.md) — gaps, sequencing, and risk.
