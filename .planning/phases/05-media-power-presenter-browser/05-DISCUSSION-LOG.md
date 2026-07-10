# Phase 5: Media, Power, Presenter & Browser - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-10
**Phase:** 5-Media, Power, Presenter & Browser
**Areas discussed:** Control-surface navigation, Volume slider + state sync, Power confirm UX, Presenter screen

---

## Area Selection

Owner answered "[No preference]" to the area-selection question — delegated
selection, same pattern as Phase 4. All four identified gray areas were then
presented as one batched confirmation round with recommended options first.

---

## Control-surface navigation

| Option | Description | Selected |
|--------|-------------|----------|
| Interim Remote hub (Recommended) | Device row opens slim hub: trackpad + tiles for Media, Power, Presenter, Browser; hub becomes Phase-7 dashboard skeleton; browser gets own small screen | ✓ |
| Tabs from trackpad | Bottom tab bar on trackpad screen; crowds full-bleed trackpad, reworked in Phase 7 | |
| Sheet overlays | Modal bottom-sheets over trackpad; cheapest but power+presenter cramped | |

**User's choice:** Interim Remote hub (Recommended)

---

## Volume slider + state sync

| Option | Description | Selected |
|--------|-------------|----------|
| vol.changed push + throttled drag (Recommended) | Additive S→C `vol.changed {value, muted}` on auth + external change; slider sends throttled setvol (~50ms) while dragging; pushes ignored during drag | ✓ |
| On-release only | Single setvol on finger lift; no live audio feedback while sliding | |
| Poll from client | Periodic client requests; chatty, battery-hostile, lags external changes | |

**User's choice:** vol.changed push + throttled drag (Recommended)

---

## Power confirm UX

| Option | Description | Selected |
|--------|-------------|----------|
| Slide + confirm dialog (Recommended) | All actions behind slide-to-confirm; lock/sleep slide sends power+confirm together; restart/shutdown slide sends power then red countdown dialog sends confirm | ✓ |
| Double slide | Second slide track for restart/shutdown; more friction, gimmicky | |
| Hold-to-confirm second step | Press-and-hold 2s button as second step; less explicit than labeled confirm | |

**User's choice:** Slide + confirm dialog (Recommended)

---

## Presenter screen

| Option | Description | Selected |
|--------|-------------|----------|
| Tap zones + manual timer (Recommended) | Giant Next (right 2/3) / Prev (left 1/3) zones; bottom bar Start/End show, Blank, elapsed timer; timer starts on Start-show tap, tap to pause/reset; wakelock; haptic per slide | ✓ |
| Swipe navigation | Swipe left/right for slides; slower for rapid advancing, error-prone blind use | |
| Timer auto-start | Timer starts on first Next instead of Start-show tap; wrong when warming up before slide 1 | |

**User's choice:** Tap zones + manual timer (Recommended)

---

## Claude's Discretion

Exact styling, tile layout, slider widget, tunable constants (throttle ms,
countdown rendering), media screen composition, mute placement, browser button
grid, slice ordering. Owner confirmed all recommended options without edits.

## Deferred Ideas

None new. Two matched todos (server one-pairing-per-run, overloaded noPairing
copy) re-reviewed and re-deferred to Phase 7 — same verdict as Phase-4 context.
