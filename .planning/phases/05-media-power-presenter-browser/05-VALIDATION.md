---
phase: 5
slug: media-power-presenter-browser
status: planned
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-10
wave_0_mapped: "Wave-0 tests embedded as RED-first TDD tasks in plans 05-01 (volume fixtures), 05-03 (vol_ integration), 05-06 (confirm_track_fsm), 05-04 (presenter_timer), 05-07 (volume_store)"
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Sourced from 05-RESEARCH.md "Validation Architecture". House style: pure
> IO-free FSMs + injected seams with unit tests; shared golden fixtures.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | built-in `#[cfg(test)]` + `#[tokio::test]` (+ paused-clock via `start_paused`) |
| **Framework (Dart)** | `flutter_test` |
| **Config file** | none — existing conventions cover both langs |
| **Quick run command** | `cd server && cargo test` / `cd app/remote_control && flutter test` |
| **Full suite command** | `cd server && cargo test` + `cd app/remote_control && flutter test` + `cd app/packages/remote_protocol && flutter test` |
| **Estimated runtime** | ~30s (Dart) + ~20s (Rust) |

---

## Sampling Rate

- **After every task commit:** Run the touched side — `flutter test` (client task) or `cargo test` for the touched crate (server task).
- **After every plan wave:** Run full `cargo test` (workspace) + both `flutter test` suites (app + remote_protocol fixtures).
- **Before `/gsd-verify-work`:** Full suites green PLUS the phase-gate on-device checks below.
- **Max feedback latency:** ~30 seconds (per-side quick run).

---

## Per-Task Verification Map

*(Requirement-level map from 05-RESEARCH.md; planner assigns final Task/Plan/Wave IDs.)*

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | MED-01 | — | media codes map to enigo keys; unknown codes dropped, never panic | unit | `cargo test -p server-windows keymap` (extend `keymap_covers_all_codes`) | ✅ pattern exists | ⬜ pending |
| TBD | TBD | TBD | MED-02 | — | `vol.changed` encode/decode byte-identical in both codecs | fixture | `cargo test -p server-core --test fixtures` / `flutter test test/fixture_test.dart` (remote_protocol) | ❌ W0 (new `volume/` fixtures) | ⬜ pending |
| TBD | TBD | TBD | MED-02 | — | push after auth, none pre-auth, push on watch change | integration | `cargo test -p server-core --test integration vol_` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | MED-02 | — | slider store: drag-ignore, 50ms throttle, authed gate | unit (FSM) | `flutter test test/media/volume_store_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | PWR-01..03 | power double-gate | power→confirm gate (window, mismatch, expiry) — no single-action restart/shutdown path | unit | `cargo test -p server-core confirm` | ✅ (router.rs tests) | ✅ green |
| TBD | TBD | TBD | PWR-01..03 | power double-gate | confirm-track FSM transitions; lock/sleep dual-send; restart/shutdown dialog flow | unit (FSM) | `flutter test test/power/confirm_track_fsm_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | PWR-02 | — | sleep = `SetSuspendState(false)` actually suspends (never hibernates) | manual | phase-gate on-device (roadmap SC2) | manual | ⬜ pending |
| TBD | TBD | TBD | PRES-01 | — | present macro table maps every action | unit | `cargo test -p server-core present_macro_table` | ✅ (router.rs) | ✅ green |
| TBD | TBD | TBD | PRES-02 | — | timer FSM start/pause/reset over injected clock | unit (FSM) | `flutter test test/presenter/presenter_timer_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BROW-01 | — | browser macro table maps every action | unit | `cargo test -p server-core browser_macro_table` | ✅ (router.rs) | ✅ green |
| TBD | TBD | TBD | BROW-01/PRES-01 | — | macros act on focused browser/PowerPoint window | manual | phase-gate on-device (SC4, SC5) | manual | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky.*

---

## Wave 0 Requirements

- [ ] `protocol/fixtures/volume/01..03-*.json` — MED-02 wire contract (both codec suites consume them; verify loader family discovery, A6)
- [ ] `server/server-core/tests/integration.rs` vol-push cases (or new `volume.rs` test) — MED-02 push gating
- [ ] `app/remote_control/test/media/volume_store_test.dart` — D-04 slider policy
- [ ] `app/remote_control/test/power/confirm_track_fsm_test.dart` — D-05/D-06 confirm flow
- [ ] `app/remote_control/test/presenter/presenter_timer_test.dart` — D-08 timer FSM
- [ ] Framework install: none — existing infrastructure covers everything

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Media keys control system playback | MED-01 | SMTC behavior depends on the running player app | On-device: play/pause, next, prev against Spotify and YouTube (browser tab) — whatever is playing responds |
| Volume slider tracks PC-side changes | MED-02 | Requires real endpoint volume + hardware keys | Change volume with PC keyboard/mixer → app slider follows within one poll tick (~250ms) |
| Sleep actually suspends | PWR-02 | Power state transition needs real hardware | Slide-to-confirm sleep → PC suspends (not hibernates); wake and confirm session recovery |
| Restart/shutdown two-gesture path | PWR-01/03 | Destructive; needs real dialog + server confirm round-trip | Slide-to-confirm, then server-side confirm message required — verify no single-action path exists |
| PowerPoint slide driving + blank + timer | PRES-01/02 | Requires focused PowerPoint slideshow | Start/end show, next/prev, blank (B key), elapsed timer runs and resets |
| Browser macros incl. zoom | BROW-01 | Requires focused browser; zoom chord behavior varies (Pitfall 11) | Back/forward, new/close tab, refresh, zoom in/out against the focused browser window |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending (planner to map final task IDs)
