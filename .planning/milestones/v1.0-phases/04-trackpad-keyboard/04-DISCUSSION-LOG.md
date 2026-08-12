# Phase 4: Trackpad & Keyboard - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-09
**Phase:** 4-Trackpad & Keyboard
**Areas discussed:** Pointer injection model, Trackpad feel & thresholds, Keyboard surface layout, Sticky modifier UX

---

## Area selection

| Option | Description | Selected |
|--------|-------------|----------|
| Pointer injection model | Absolute vs relative injection (folds the score-0.9 todo) | |
| Trackpad feel & thresholds | Acceleration curve, tap/scroll/drag thresholds; benchmark Remote Mouse | |
| Keyboard surface layout | IME text + toggleable special-key rows; panel vs screen | |
| Sticky modifier UX | Visible held state + auto-reset semantics; chording; autorepeat | |

**User's choice:** "No preference" — owner delegated area selection to Claude.
**Notes:** Claude proposed recommended decisions across all four areas and asked for a single confirm/adjust.

---

## Confirmation of proposed decisions

| Option | Description | Selected |
|--------|-------------|----------|
| Lock all four | Absolute injection; Remote-Mouse-benchmarked feel + on-device tuning; expandable keyboard panel over the trackpad; auto-reset-after-next-key sticky modifiers with long-press-to-lock | ✓ |
| Adjust pointer injection | Keep relative + disable-setting workaround / discuss more | |
| Adjust keyboard/modifiers | Different mental model for keyboard surface or modifier reset | |
| Let me describe changes | Redirect in owner's own words | |

**User's choice:** Lock all four.
**Notes:** Owner accepted the four proposed decisions verbatim (D-01..D-12 in CONTEXT.md).

---

## Claude's Discretion

- Which areas to discuss (owner had no preference).
- Exact gesture constants, acceleration curve shape, thresholds — deferred to on-device tuning during execution (D-06).
- Widget structure, MVP slice ordering (SPIDR during planning), executor internals.

## Deferred Ideas

- Gyro/air-mouse mode (FEAT-01) — backlog.
- UDP mouse-delta channel (TRAN-01) — not triggered; ws:// gate passed.
- Server one-pairing-per-run todo — Phase 7 (persistence), not input.
- Overloaded `noPairing` copy todo — server-protocol follow-up, not input.
