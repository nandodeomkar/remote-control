---
phase: 8
slug: floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
status: approved
nyquist_compliant: true
wave_0_complete: true
created: 2026-07-15
---

# Phase 8 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from 08-RESEARCH.md § Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | `flutter_test` (bundled with Flutter 3.44.5) |
| **Config file** | none — standard `test/` tree under `app/remote_control/` |
| **Quick run command** | `flutter test test/trackpad/ test/bubble_scaffold_test.dart test/trackpad_bubble_test.dart test/floating_trackpad_window_test.dart` (scoped) |
| **Full suite command** | `flutter test` (from `app/remote_control/`) + `flutter analyze` |
| **Estimated runtime** | ~30–60 seconds (full suite) |

---

## Sampling Rate

- **After every task commit:** Run the scoped quick run for the file(s) touched.
- **After every plan wave:** Run `flutter test` (full suite) + `flutter analyze`.
- **Before `/gsd-verify-work`:** Full suite + analyzer must be green.
- **Max feedback latency:** ~60 seconds.

---

## Per-Task Verification Map

> Task IDs are assigned by the planner; this map is keyed by area/behavior and cross-walks to
> the test file each task's `<automated>` block must target.

| Area | Wave | Behavior | Threat Ref | Test Type | Automated Command | File Exists |
|------|------|----------|------------|-----------|-------------------|-------------|
| Extraction net | 0 | Pointer events on `TrackpadCore` reach a fake classifier/driver seam; zero setState | — | widget | `flutter test test/trackpad/trackpad_core_test.dart` | ❌ W0 |
| CR-01 flush | 0 | `DragMsg(end)` sent ONLY when drag-locked AND authed (4-quadrant) on core dispose | server input integrity | unit/widget | `flutter test test/trackpad/trackpad_core_test.dart` | ❌ W0 |
| keepAwake | 0 | Core mount acquires / dispose releases; Presenter hold survives a window excursion | — | unit/widget | `flutter test test/keep_awake_test.dart` | ⚠️ extend |
| Composition | 0 | `TrackpadScreen` renders surface + drag-lock pill + tune + keyboard toggle after slimming | — | widget | `flutter test test/trackpad/trackpad_screen_test.dart` | ❌ W0 |
| Bubble drag/snap | 1 | Drag → snaps to nearest edge; position notifier updated; 8px inset | Tampering/DoS-of-UX | widget | `flutter test test/trackpad_bubble_test.dart` | ❌ W0 |
| Bubble tap/haptic | 1 | Tap fires expand callback + haptic tick | — | widget | `flutter test test/trackpad_bubble_test.dart` | ❌ W0 |
| Bubble muted | 1 | `kSurface` fill + muted icon when not authed; still tappable | — | widget | `flutter test test/trackpad_bubble_test.dart` | ❌ W0 |
| Window header drag | 1 | Header pan moves + clamps window; surface touches do NOT move it | — | widget | `flutter test test/floating_trackpad_window_test.dart` | ❌ W0 |
| Window header buttons | 1 | `⤢`/`✕` fire callbacks; drag-lock pill appears via listenable | — | widget | `flutter test test/floating_trackpad_window_test.dart` | ❌ W0 |
| Scaffold presence | 1 | Bubble present on tool screens, absent with `showBubble:false`; UIPI slot unchanged; body around open window hit-testable | — | widget | `flutter test test/bubble_scaffold_test.dart` | ❌ W0 |
| Bubble persistence | 1 | `(edge, yFraction)` round-trip + default `(right, 0.70)` + corrupt-read degrade | Tampering/DoS-of-UX | unit | `flutter test test/bubble_position_test.dart` | ❌ W0 |
| Window persistence | 1 | `(x, y)` round-trip + unset-sentinel default + corrupt-read degrade | Tampering/DoS-of-UX | unit | `flutter test test/window_position_test.dart` | ❌ W0 |
| Migration | last | `QuickBarScaffold` symbols gone; hub compiles against `BubbleScaffold` | — | build | `flutter analyze && flutter test` | ✅ compile-time |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `test/trackpad/trackpad_core_test.dart` — extraction net: pointer→seam, zero-setState, CR-01 4-quadrant, keepAwake count. **(Primary safety net — Pitfall 7.)**
- [ ] `test/trackpad/trackpad_screen_test.dart` — thin-composition smoke test (currently NONE exists).
- [ ] `test/trackpad_bubble_test.dart` — drag/snap/tap/haptic/muted.
- [ ] `test/floating_trackpad_window_test.dart` — header drag/clamp, buttons, pill, surface-is-mouse.
- [ ] `test/bubble_scaffold_test.dart` — presence/absence, UIPI slot, body hit-testable (supersedes `test/quick_bar_test.dart`; delete that file).
- [ ] `test/bubble_position_test.dart`, `test/window_position_test.dart` — persistence round-trips (mirror `scroll_direction_test.dart` / `device_store_test.dart`).
- [ ] Extend `test/keep_awake_test.dart` for the window-excursion / Presenter-survival scenario.
- Framework install: none — `flutter_test` already present.

---

## Manual-Only Verifications

| Behavior | Why Manual | Test Instructions |
|----------|------------|-------------------|
| Cursor latency from the window indistinguishable from the full screen | Perceptual latency; parity is structural but confirm on-device | Move cursor from window vs full screen on same LAN; no perceptible difference |
| Drag bubble + window on every tool screen; positions restore after app restart | Requires real device + app lifecycle | Drag both on each tool screen; kill + relaunch; confirm restored positions |
| Power screen + window overlap: power double-confirm flow unobstructed | Requires real gesture/layout interaction | Open window over Power screen; drag clear; confirm both power confirmation taps land |
| Reconnect/disconnect while window open | Requires real network drop | Drop WiFi with window open; confirm muted state, `driver.reset` on drop, no stuck drag |
| Presenter + window: keep-awake never drops during window excursion | Requires real screen-wake observation | Open/close window while on Presenter; screen stays awake throughout |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (authored in 08-02 Task 1 before the extraction lands)
- [x] No watch-mode flags
- [x] Feedback latency < 60s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-07-15
