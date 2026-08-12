---
phase: 4
slug: trackpad-keyboard
status: mapped
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-09
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Sourced from 04-RESEARCH.md "Validation Architecture". House style: pure
> IO-free FSMs + injected seams with unit tests; shared golden fixtures.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Dart)** | `flutter_test` / `test` (per `app/remote_control/test/*`, `remote_protocol/test/*`) |
| **Framework (Rust)** | built-in `#[cfg(test)]` + `#[tokio::test]` (per `router.rs`, `input_thread.rs` tests) |
| **Config file** | none — existing infrastructure covers both langs |
| **Quick run command** | `cd app/remote_control && flutter test` · `cd server && cargo test` |
| **Full suite command** | `cd server && cargo test --workspace` + `cd app/remote_control && flutter test` + fixture suites |
| **Estimated runtime** | ~30s (Dart) + ~20s (Rust) |

---

## Sampling Rate

- **After every task commit:** Run the touched side — `flutter test` (client task) or `cargo test` for the touched crate (server task).
- **After every plan wave:** Run full `cargo test --workspace` + `flutter test` + fixture suites.
- **Before `/gsd-verify-work`:** Full suites green PLUS the phase-gate on-device checks below.
- **Max feedback latency:** ~30 seconds (per-side quick run).

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| server-inject | 04-01 (T1/T2) | 1 | PAD-01/03 | T-04-01 | absolute inject never targets outside the virtual desktop | unit (pure fn) | `cargo test -p server-windows normalize_virtual` | ❌ W0 | ⬜ pending |
| sub-pixel | (exists) | 1 | PAD-01 | — | fractional deltas carried, never dropped | unit | `cargo test sub_integer_deltas` | ✅ | ✅ green |
| keymap | 04-02 (T2) | 2 | KEY-02 | T-04-02 | every client key.code maps to a Some(Key); unknown codes dropped, never panic | unit | `cargo test -p server-windows keymap` | ❌ W0 | ⬜ pending |
| key-down-up | 04-02 (T1) | 2 | KEY-04 | T-04-04 | held keys released on session end (CONN-07) | unit + manual | `cargo test key_down_up_updates_held` | ✅ (routing) | ⬜ pending |
| gesture-fsm | 04-03 (T1) | 1 | PAD-02/03/04 | — | classifier emits move/tap/2tap/scroll/drag intents deterministically | unit (FSM) | `flutter test test/trackpad/gesture_classifier_test.dart` | ❌ W0 | ⬜ pending |
| accel-curve | 04-03 (T2) | 1 | PAD-01 | — | accel curve maps deltas deterministically; sensitivity honored | unit | `flutter test test/trackpad/accel_test.dart` | ❌ W0 | ⬜ pending |
| scroll-volatile | 04-03 (T3) | 1 | PAD-03 | T-04-05 | pre-auth scroll frames dropped, never queued (sendMove-identical gate) | unit | `flutter test test/connection_service_test.dart` | ✅ (extend) | ⬜ pending |
| trackpad-driver | 04-04 (T1) | 3 | PAD-01..04 | T-04-06 | momentum cancels on touch/disconnect/dispose; drag-lock resets on disconnect | unit (seam) | `flutter test test/trackpad/trackpad_driver_test.dart` | ❌ W0 | ⬜ pending |
| mouse-buttons | 04-04 (T2) | 3 | PAD-02 | — | L/M/R emit correct button strings; gated bar inert | widget | `flutter test test/trackpad/mouse_buttons_test.dart` | ❌ W0 | ⬜ pending |
| diff-ops | (exists) + 04-05 (T1) | 4 | KEY-01 | T-04-03 | computeDiff reproduces the shared text fixtures (grapheme-exact); producer diffs committed transitions + sentinel reseed; ins never logged | unit | `flutter test test/keyboard/ime_diff_producer_test.dart` | ✅ helper / ❌ W0 wrapper | ⬜ pending |
| keyboard-panel | 04-05 (T3) | 4 | KEY-01 | — | panel focus raises/lowers IME; hidden input survives toggle | widget | `flutter test test/keyboard/keyboard_panel_test.dart` | ❌ W0 | ⬜ pending |
| modifier-fsm | 04-06 (T1) | 5 | KEY-03 | T-04-04 | arm/lock/chord/auto-reset + reset-on-disconnect (no effects on dead socket) | unit (FSM) | `flutter test test/keyboard/modifier_fsm_test.dart` | ❌ W0 | ⬜ pending |
| key-rows | 04-06 (T2) | 5 | KEY-02/04 | T-04-02 | every emitted code ∈ kClientKeyCodes (mirror of keymap.rs); down/up hold vs tap+mods branch | widget | `flutter test test/keyboard/key_rows_test.dart` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky.*

---

## Wave 0 Requirements

- [ ] `server-windows` pure `normalize_virtual(x, y, metrics)` fn extracted + unit test (absolute-inject normalization testable without a display) — PAD-01/03 (04-01 T1)
- [ ] `keymap.rs` coverage test — every client `key.code` → `Some(Key)` — KEY-02 (04-02 T2)
- [ ] `app/remote_control/test/trackpad/gesture_classifier_test.dart` — PAD-02/03/04 classifier FSM (04-03 T1)
- [ ] `app/remote_control/test/trackpad/accel_test.dart` — PAD-01 curve/sensitivity (04-03 T2)
- [ ] `app/remote_control/test/keyboard/modifier_fsm_test.dart` — KEY-03 sticky-modifier FSM (04-06 T1)
- [ ] Pure classifier / diff-producer / normalization seams must be IO-free so they unit-test without a device (house style)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Trackpad feel vs Remote Mouse | PAD-01..04 | Feel is subjective; D-05/D-06 mandate on-device tuning | On the Xiaomi + Windows: move/tap/right-tap/scroll-momentum/drag-lock all feel at least as good as Remote Mouse; tune constants in `tuning.dart` + sensitivity slider only |
| Ballistics bypass + multi-monitor seam | PAD-01/03 | Requires a real display (and a 2nd monitor) | With "Enhance pointer precision" ON, slow drags still move the cursor 1:1; on a dual-monitor PC the cursor crosses the seam without warping |
| IME typing fidelity | KEY-01 | Real device IME (autocomplete/emoji/backspace) | Type with autocomplete, insert emoji (👋🏽), rapid-backspace → PC text matches exactly; backspace past session text still deletes on the PC (sentinel) |
| Autorepeat on hold | KEY-04 | Real key-hold timing | Hold an on-screen key → PC autorepeats; release → stops immediately (no phantom repeat) |
| Sticky-modifier combos + disconnect reset | KEY-03 / D-12 | Real OS combo behavior + real disconnect | Arm Win, tap D → desktop + auto-reset; lock Ctrl, hold Right → word-jump repeat; kill connection mid-lock → chips reset, nothing held on the PC |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter (planner mapped final task IDs 2026-07-09)

**Approval:** planner-mapped (final task IDs assigned across plans 04-01..04-06)
