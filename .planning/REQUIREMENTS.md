# Requirements: Remote Control — v1.1 "The Summon Bar"

**Defined:** 2026-08-13
**Core Value:** Phone controls the laptop over WiFi with zero friction: instant cursor response, full keyboard, and the control-center extras (media, power, apps, clipboard, presenter, browser) — all free.

**Milestone goal:** Trackpad and keyboard stop being destinations — a permanent bottom
bar on every screen raises them in place, so both are always one tap away alongside
every other remote.

**Scope note:** this milestone is **pure Flutter client UI**. No Rust server work, no
protocol change, no `protoVersion` bump. Requirement IDs use fresh prefixes; v1.0's
(`APPS BROW CLIP CONN FEAT KEY MED PAD PLAT PRES PWR SRV TRAN UI`) are retired to
`milestones/v1.0-REQUIREMENTS.md`.

## v1.1 Requirements

### The Bar

- [x] **BAR-01**: A permanent bottom bar carrying a trackpad icon and a keyboard icon is visible on the hub and on every tool screen
- [x] **BAR-02**: The bar stays visible and tappable while a surface is raised — the surface sits on top of it, never under it
- [ ] **BAR-03**: The keyboard icon is disabled whenever a local text field holds focus, so a pairing PIN can never be typed into the PC
- [ ] **BAR-04**: The bar is suppressed entirely on the QR scan screen
- [x] **BAR-05**: Every screen's content stays fully reachable with the bar present — nothing clipped or stranded behind it

### Summon & Dismiss

- [x] **SUM-01**: Tapping a bar icon raises that surface over the current screen without navigating away
- [ ] **SUM-02**: Nothing beneath a raised surface resizes or reflows, and a tappable widget outside the surface still receives its tap
- [x] **SUM-03**: Tapping the same bar icon again dismisses the raised surface
- [x] **SUM-04**: The Android back gesture dismisses a raised surface before it pops the screen
- [ ] **SUM-05**: A 48dp drag handle offers a third dismiss route that assistive services can drive
- [ ] **SUM-06**: No gesture on the surface body dismisses it — 30 consecutive full-height cursor throws and 30 two-finger scrolls produce zero dismissals

### The Raised Surfaces

- [ ] **SURF-01**: The raised trackpad moves, clicks, scrolls and drags the PC cursor exactly as the full Trackpad screen does
- [ ] **SURF-02**: The raised keyboard offers the same four pads — Type, Arrows, Numpad, Fn
- [ ] **SURF-03**: Re-summoning restores which pad was showing, correct on the first frame with no visible hop — including the first summon after app launch
- [ ] **SURF-04**: Typing from a raised keyboard works on any screen with no dead first keystroke after a summon

### Input Safety

- [ ] **SAFE-01**: Dismissing the keyboard releases every held *and locked* modifier on the PC
- [ ] **SAFE-02**: Dismissing the trackpad with drag-lock engaged releases the PC's left mouse button
- [ ] **SAFE-03**: The "input blocked — elevated window" advisory still reaches the user after the bubble is retired

### Retirement & Hub

- [ ] **RET-01**: The floating trackpad bubble and its floating window are gone from the app
- [ ] **RET-02**: Trackpad and Keyboard tiles remain reachable at the end of the hub grid
- [ ] **RET-03**: The full Trackpad screen remains a meaningfully larger cursor surface than the raised one

### Motion

- [x] **MOT-01**: Summon completes in 200ms and dismiss in 150ms
- [ ] **MOT-02**: Summon and dismiss stay smooth under repeated use, with worst-frame UI and raster times recorded from a 20-cycle trace

### Chip Row

- [ ] **CHIP-01**: The modifier chip row is verified on a real 360dp viewport with the shipped font, and any user-visible overflow is fixed on all three keyboard surfaces
- [ ] **CHIP-02**: The overflow guard no longer depends on the widget-test font — it asserts no overflow rather than asserting a non-zero overflow drain

## Future Requirements

Deferred beyond v1.1. Tracked, not in this roadmap.

### Hub

- **HUBF-01**: Delete the Trackpad and/or Keyboard hub tile once the bar has been lived with. Deliberately deferred — deleting a tile is a one-line follow-up, un-deleting one is not. Revisit only after real use, never before.

### Keyboard

- **KBDF-01**: A locked-modifier indicator on the summon bar, tappable to release. Considered and rejected during quick `260812-tsw` in favour of releasing the lock on dismiss. It would preserve "lock Shift → dismiss → drag-select on the still-live trackpad", a real flow. Revisit only if that flow is missed in dogfooding; the cost of reversing is one method call.

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| IME-style content resize beneath the raised surface | Nothing on the phone is the input target — every keystroke and cursor delta goes to the PC, so there is no field to keep visible. Converting this into a resize/inset contract solves a problem this app does not have, at the cost of making every tool screen scrollable |
| Restoring modifier state across a dismiss | Restore *layout*, reset *input state*. Restoring a locked Ctrl would be restoring a hazard; nobody expects a modifier to survive a dismiss they performed deliberately |
| Deleting either hub tile | Fully reversible only in one direction — see HUBF-01. The full Trackpad screen is the precision surface and the docked keyboard-over-live-trackpad is a genuinely different mode |
| Any server, protocol or extension change | This milestone is client-side Flutter only. No `protoVersion` bump, so no two-sided release coupling |
| The ten v1.0 deferred items | Acknowledged at the v1.0 close and unchanged by this milestone. See `STATE.md` `## Deferred Items` |
| A dismiss gesture on the surface body | The trackpad is a raw `Listener` that never enters the gesture arena, so an ancestor `GestureDetector` wins uncontested after ~18dp of slop while the cursor has been moving since 10dp. Every dismiss would nudge the PC cursor — invisibly, since the user is looking at the laptop |
| `OverlayPortal`, `showModalBottomSheet`, and every third-party sheet package | All route- or portal-based, so all destroy child State on dismiss — which breaks both SURF-03 (restore) and SURF-04 (the Android IME connection). Zero new dependencies |

## Traceability

Which phases cover which requirements. Populated during roadmap creation 2026-08-13.

Phase numbering **continues** from v1.0 — v1.1 runs **Phases 13-18**, it does not reset to 1.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BAR-01 | Phase 13 — Summon Shell & Bar | Complete |
| BAR-02 | Phase 13 — Summon Shell & Bar | Complete |
| BAR-03 | Phase 13 — Summon Shell & Bar | Pending |
| BAR-04 | Phase 13 — Summon Shell & Bar | Pending |
| BAR-05 | Phase 13 — Summon Shell & Bar | Complete |
| SUM-01 | Phase 13 — Summon Shell & Bar | Complete |
| SUM-02 | Phase 13 — Summon Shell & Bar | Pending |
| SUM-03 | Phase 13 — Summon Shell & Bar | Complete |
| SUM-04 | Phase 13 — Summon Shell & Bar | Complete |
| SUM-05 | Phase 14 — Raised Trackpad | Pending |
| SUM-06 | Phase 14 — Raised Trackpad | Pending |
| SURF-01 | Phase 14 — Raised Trackpad | Pending |
| SURF-02 | Phase 15 — Raised Keyboard | Pending |
| SURF-03 | Phase 15 — Raised Keyboard | Pending |
| SURF-04 | Phase 15 — Raised Keyboard | Pending |
| SAFE-01 | Phase 15 — Raised Keyboard | Pending |
| SAFE-02 | Phase 14 — Raised Trackpad | Pending |
| SAFE-03 | Phase 16 — Bubble Retirement | Pending |
| RET-01 | Phase 16 — Bubble Retirement | Pending |
| RET-02 | Phase 17 — Hub Tiles & Bar Identity | Pending |
| RET-03 | Phase 14 — Raised Trackpad | Pending |
| MOT-01 | Phase 13 — Summon Shell & Bar | Complete |
| MOT-02 | Phase 18 — Chip Row & Measured Motion | Pending |
| CHIP-01 | Phase 18 — Chip Row & Measured Motion | Pending |
| CHIP-02 | Phase 18 — Chip Row & Measured Motion | Pending |

**Coverage:**

- v1.1 requirements: 25 total
- Mapped to phases: 25 ✓
- Unmapped: 0
- Duplicated across phases: 0

**Per-phase counts:** Phase 13 → 10 · Phase 14 → 5 · Phase 15 → 4 · Phase 16 → 2 ·
Phase 17 → 1 · Phase 18 → 3.

### Placements a later reader will otherwise re-open

| Requirement | Placed in | Why not the obvious phase |
|---|---|---|
| SAFE-03 (UIPI advisory survives) | 16, with the deletion | `bubble_scaffold.dart:181` is the **only** production mount of `UipiBanner` in `lib/`. The shell builds the slot in Phase 13, but the requirement is only *at risk* — and only provable — in the phase that deletes the old mount. The rehoming must ship in the same plan as the delete, or the SRV-05 advisory leaves the product silently and no test notices |
| RET-03 (full screen stays more precise) | 14, not 17 | It is a property of the *raised* trackpad's geometry, judged on hardware the moment that surface first exists. It is also the justification for RET-02 — if it fails, the tile-survival rationale evaporates, and Phase 17 needs that answer before it starts |
| MOT-01 (200ms / 150ms) | 13, not 18 | The animation lives in the shell and is fully exercised by the empty overlay; the constants and the t=100ms/t=250ms assertions belong where they are written. MOT-02 (worst-frame trace under repeated use with real surface content) is the half that genuinely needs both surfaces to exist, and it lands in Phase 18 |
| SUM-02 (nothing beneath reflows; outside taps still land) | 13 | A host property, provable against an empty overlay. The retiring bubble suite's version of that same test is separately carried into Phase 16's success criteria as a migration contract — that is a test-survival obligation, not a second requirement mapping |

## Decisions Folded In

Recorded here because each was a live question answered by the owner during
`/gsd-new-milestone` on 2026-08-13, and a later reader will otherwise re-open them.

| Question | Decision | Consequence |
|---|---|---|
| Does the bar ride the hub? | **Yes, every screen including the hub** | Reverses D8-05, which scoped the bubble to tool screens and excluded the hub. Drives BAR-01 |
| Bar behaviour on pairing screens | **Keyboard icon gated on focus; QR suppressed** | Chosen over a screen allowlist because it stays correct for any future screen that gains a text field. Drives BAR-03/BAR-04 |
| The 7.3px chip overflow | **Verify before fixing** | Research argues it is a widget-test-font artifact (`Shift` = 5 × 16px = 80dp in a 74dp cell under the test face). Drives CHIP-01's "user-visible" qualifier |
| How "quick" is judged | **Budget pinned in spec, on-device UAT as the gate** | 200ms summon / 150ms dismiss / zero-frame restore. Drives MOT-01 and closes OQ-A1 sub-questions 2–4; sub-question 1 closes at UAT |

---
*Requirements defined: 2026-08-13*
*Last updated: 2026-08-13 — traceability populated by roadmap creation (Phases 13-18, 25/25 mapped)*
