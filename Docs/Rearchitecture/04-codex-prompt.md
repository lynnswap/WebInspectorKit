# Retired Codex Task Prompt — Superseded by 05

Status: retired (2026-07-02).

This file used to contain the implementation prompt for the
`03-design-doc.md` direction: a two-product `WebInspectorCore` +
`WebInspectorKit` migration that promoted the existing observable model layer.
That direction is no longer the active public-surface design.

Do not use this file as an implementation prompt.

Use [05-two-layer-sdk-design.md](05-two-layer-sdk-design.md) as the current
interface sketch instead. The implementation prompt should be regenerated after
the gate checklist in
[06-implementation-gate.md](06-implementation-gate.md) is filled from the
current code.

Minimum read order for a future regenerated prompt:

1. [01-scope-contract.md](01-scope-contract.md)
2. [02-findings.md](02-findings.md)
3. [05-two-layer-sdk-design.md](05-two-layer-sdk-design.md)
4. [06-implementation-gate.md](06-implementation-gate.md)
5. [measurements/](measurements/)
6. Repo-local instructions and validation docs
