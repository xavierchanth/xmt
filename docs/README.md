# XMT documentation

This is the documentation index for XMT — Xavier's macOS Tweaks. It routes readers to the product statement, the intended architecture, the specification of released behavior, and the roadmap that records delivery state and gaps.

## Authority model

XMT documentation is **future-first**: architecture pages describe the intended end state of the app, whether or not that state ships today.

Source and tests under `XMT/` and `XMTTests/` are the **final authority on exact released behavior**, above every page in this tree. Where a documentation page and the code disagree about what the app does, the code is correct and the page is a defect to fix.

Among documentation pages, when two of them overlap:

1. [Specification](specification/README.md) — normative behavior of implemented modules. It wins over architecture on anything the app actually does.
2. [Architecture](architecture/README.md) — intended boundaries, ownership, and rationale. It governs where things belong and why, not what currently happens.

Ownership, which is separate from precedence:

- The [roadmap](roadmap/README.md) is the sole owner of delivery state, implementation gaps, sequencing, and risk. No other page states or ranks those; other pages link to it.
- [Product](PRODUCT.md) owns the goals, non-goals, naming, and the rationale for the app's shape.

Nothing in `architecture/` should be read as a claim that a module exists. Nothing in `specification/` describes a module that has not shipped.

## Start here

1. [Product](PRODUCT.md) — what XMT is for, who it serves, and why it is a single app instead of several.
2. [Architecture](architecture/README.md) — the intended app shell and module model.
3. [Specification](specification/README.md) — normative behavior of what is implemented today.
4. [Roadmap](roadmap/README.md) — implementation gaps, sequencing, and risk.

## Related documentation

- [Voice hardware QA checklist](qa/voice-transcription.md) — the deferred manual procedure for microphone, Speech, trigger, recovery, and paste validation.
- [Repository README](../README.md) — build, run, and test instructions.
- [Agent and contributor guidance](../AGENTS.md) — working conventions, including documentation rules.
