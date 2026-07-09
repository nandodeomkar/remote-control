---
phase: 04-trackpad-keyboard
plan: 06
subsystem: ui
tags: [flutter, riverpod, shared_preferences, keyboard, sticky-modifiers, autorepeat]

# Dependency graph
requires:
  - phase: 04-trackpad-keyboard (04-02)
    provides: keymap.rs CLIENT_KEY_CODES — the ONE locked key.code vocabulary + server hold/tap executors
  - phase: 04-trackpad-keyboard (04-05)
    provides: KeyboardPanel shell (D-07) with the rows slot, HiddenTextInput, ImeDiffProducer
  - phase: 04-trackpad-keyboard (04-04)
    provides: sensitivity.dart prefs store/provider house pattern; changes-subscription disconnect hygiene
  - phase: 03-connect-flow
    provides: ConnectionService (sendReliable, changes, chipStatus), CONN-07 release_all server-side
provides:
  - ModifierFsm — pure armed/locked two-level sticky-modifier FSM (tap/longPress/onNonModifierTap/disconnected, effects out)
  - ModifierChip — rest/armed-outline/locked-solid+lock/disabled chip visuals (200ms ease, ≥48px)
  - KeyRows + KeyRowGroupSwitcher + kClientKeyCodes — Nav/Fn/Num toggleable rows mirroring keymap.rs byte-for-byte
  - keyboard.rowGroup persisted selection (KeyRowGroupStore over PrefsKv + Riverpod Notifier, default nav)
  - KeyboardPanel rows slot filled: chips row + switcher + active row, all three KeyMsg paths wired, D-12 reset
affects: [04-VALIDATION on-device gate, phase-5 control-center key macros, phase-7 settings]

# Tech tracking
tech-stack:
  added: []
  patterns: [pure-FSM-effects-out (reconnect_fsm style) for modifier state, PrefsKv seam for typed pref stores, callback-injected widgets (no service imports) for widget-testability, ValueKey('cap-<code>') test targeting]

key-files:
  created:
    - app/remote_control/lib/keyboard/modifier_fsm.dart
    - app/remote_control/lib/keyboard/modifier_chip.dart
    - app/remote_control/lib/keyboard/key_rows.dart
    - app/remote_control/test/keyboard/modifier_fsm_test.dart
    - app/remote_control/test/keyboard/key_rows_test.dart
  modified:
    - app/remote_control/lib/keyboard/keyboard_panel.dart
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/test/keyboard/keyboard_panel_test.dart

key-decisions:
  - "LOCKED modifier = physical hold via keymap.rs hold codes (KeyMsg down/up), excluded from modsForTap — Pitfall 7 double-apply avoidance; ARMED rides the mods array of the next tap only"
  - "disconnected() resets all modifier state with ZERO effects — CONN-07 release_all already freed real keys; ups into a dead/new session would be wrong"
  - "Panel forgets _heldCode on disconnect so a queued stale key-up can never flush into a NEW session (the reliable queue survives blips)"
  - "Row-group store rides the PrefsKv seam (device_store house pattern) instead of raw SharedPreferencesAsync — unit-testable without a platform instance"
  - "Cap press branch is captured at press-down: armed mods present => defer to tap+mods on release; else immediate down (Windows autorepeats) + up on release/cancel"

patterns-established:
  - "Cross-language vocabulary mirror: kClientKeyCodes <-> CLIENT_KEY_CODES with coverage tests on both sides; any change lands in BOTH files"
  - "Panel-injected service seams (send/changes/isDisconnected) keep keyboard widgets fake-stream testable"

requirements-completed: [KEY-02, KEY-03, KEY-04]

# Metrics
duration: 13min
completed: 2026-07-09
---

# Phase 4 Plan 06: Special-key rows + sticky modifiers + autorepeat Summary

**Toggleable Nav/Fn/Num key rows, armed/locked sticky modifier chips sending real combos via a pure ModifierFsm, and server-side hold autorepeat — all emitting the exact keymap.rs vocabulary with a byte-identical Dart mirror and D-12 disconnect reset**

## Performance

- **Duration:** 13 min
- **Started:** 2026-07-09T20:25:33Z
- **Completed:** 2026-07-09T20:38:57Z
- **Tasks:** 3
- **Files modified:** 8

## Accomplishments

- `ModifierFsm` (pure Dart, zero imports): tap arms (rides the next tap's `mods` then auto-resets, D-10), long-press locks as a REAL server-side held key via the keymap.rs hold codes (`ControlLeft`/`AltLeft`/`ShiftLeft`/`WinLeft`) so held-key combos autorepeat with the modifier applied (RESEARCH Open Q2/Pitfall 7 closed); `disconnected()` resets everything with zero effects (D-12) — 7 unit tests
- `kClientKeyCodes` mirrors keymap.rs `CLIENT_KEY_CODES` byte-for-byte (39 codes, verified identical in content AND order both directions) — every cap the client draws maps to a real enigo key, no silently dropped keys (KEY-02)
- Nav (default)/Fn/Num toggleable rows with inverted-T arrows, 48px-floor caps, group switcher persisted under `keyboard.rowGroup` (D-09); press-down sends `key down` so WINDOWS autorepeats until the release's `up` — never client tap-spam (KEY-04, D-11); armed mods defer the press to one `tap+mods` combo on release (D-10)
- Panel rows slot filled in UI-SPEC order (chips → lg gap → switcher → active row); all three KeyMsg emission paths ride `service.sendReliable`; the D-12 disconnected transition (proven via a fake changes stream in widget tests) resets chips and forgets the held cap with zero wire sends
- Full app suite 230 tests green, `flutter analyze` clean, `cargo test -p server-windows keymap` green (no server drift)

## Task Commits

Each task was committed atomically:

1. **Task 1: ModifierFsm (TDD)** - `e9f4259` (test — RED) + `957de54` (feat — GREEN)
2. **Task 2: Key rows + group switcher + kClientKeyCodes mirror** - `a5765fb` (feat)
3. **Task 3: ModifierChip visuals + panel wiring + D-12 reset** - `e647ce5` (feat)

## Files Created/Modified

- `app/remote_control/lib/keyboard/modifier_fsm.dart` - pure sticky-modifier FSM: arm/lock/chord/auto-reset/disconnect-reset, effects out
- `app/remote_control/lib/keyboard/modifier_chip.dart` - chip widget: rest / armed-outline / locked-solid+lock-icon / disabled, 200ms ease
- `app/remote_control/lib/keyboard/key_rows.dart` - kClientKeyCodes mirror, KeyRowGroup store/provider (`keyboard.rowGroup`), KeyRows + KeyRowGroupSwitcher widgets
- `app/remote_control/lib/keyboard/keyboard_panel.dart` - rows slot filled; owns the ModifierFsm; KeyMsg wiring for hold/down-up/tap+mods; D-12 reset off the injected changes stream
- `app/remote_control/lib/trackpad/trackpad_screen.dart` - passes enabled/send/changes/isDisconnected seams into the panel
- `app/remote_control/test/keyboard/modifier_fsm_test.dart` - 7 FSM tests incl. hold-code table and zero-effect disconnect
- `app/remote_control/test/keyboard/key_rows_test.dart` - vocabulary coverage gate, down/up-vs-tap branch matrix, 48px floor, switcher persistence
- `app/remote_control/test/keyboard/keyboard_panel_test.dart` - 04-05 shell tests updated + 6 new wiring tests incl. the D-12 fake-stream proof

## Decisions Made

- LOCKED modifiers are physical holds (`key {code: hold-code, action: down/up}`) and never appear in `modsForTap()` — the down/up autorepeat path carries no mods, so this is the only model where Ctrl+held-Right repeats as Ctrl+Right (Pitfall 7); armed modifiers are client-local and ride the next tap's `mods` array only
- `disconnected()` emits zero effects by design: the socket is gone, CONN-07 release_all freed the real keys, and a queued `up` would leak into the next session — the panel additionally forgets `_heldCode` so `onKeyUp` after a drop is a no-op
- Row-group persistence uses the `PrefsKv` seam (device_store house pattern) rather than a raw injectable `SharedPreferencesAsync`: the latter's constructor throws `StateError` in tests without a platform instance, making it un-unit-testable

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] KeyRows needed two extra seams beyond the plan's 5-callback signature**
- **Found during:** Task 2 (Key rows)
- **Issue:** The plan-specified widget test matrix ("with the tap-with-mods branch signalled") requires KeyRows itself to pick the down/up-vs-tap branch at press-down, and UI-SPEC requires a haptic tick on key-down — neither is expressible with only the 5 planned callbacks without importing the service
- **Fix:** Added `hasArmedMods: bool Function()` (the branch signal, wired by the panel to `fsm.modsForTap().isNotEmpty`) and optional `onPressHaptic` (wired to `HapticFeedback.lightImpact`)
- **Files modified:** app/remote_control/lib/keyboard/key_rows.dart
- **Verification:** key_rows_test branch matrix passes; widget stays service-import-free
- **Committed in:** a5765fb

**2. [Rule 3 - Blocking] Persistence test seam: fake PrefsKv instead of SharedPreferences.setMockInitialValues**
- **Found during:** Task 2 (Key rows)
- **Issue:** The plan named `SharedPreferences.setMockInitialValues`, which only mocks the LEGACY SharedPreferences API; the house store pattern uses `SharedPreferencesAsync`, whose constructor throws `StateError` in tests with no platform instance
- **Fix:** `KeyRowGroupStore` takes the existing `PrefsKv` seam (SharedPrefsKv real adapter by default); tests inject an in-memory fake — same guarantee, zero new dependencies
- **Files modified:** app/remote_control/lib/keyboard/key_rows.dart, test/keyboard/key_rows_test.dart
- **Verification:** persistence test proves 'fn' lands under the literal `keyboard.rowGroup` key
- **Committed in:** a5765fb

**3. [Rule 3 - Blocking] keyboard_panel_test.dart updated (not in the plan's files_modified list)**
- **Found during:** Task 3 (panel wiring)
- **Issue:** The panel's new required params (enabled/send/changes/isDisconnected) broke the 04-05 shell tests' constructor calls
- **Fix:** Updated the host harness (ProviderScope + store override + fake seams); all three 04-05 contracts still assert unchanged behavior
- **Files modified:** app/remote_control/test/keyboard/keyboard_panel_test.dart
- **Verification:** all 9 panel tests green (3 preserved 04-05 + 6 new 04-06)
- **Committed in:** e647ce5

---

**Total deviations:** 3 auto-fixed (all Rule 3 blocking/test-seam)
**Impact on plan:** All fixes were required to implement the plan's own test matrix and keep suites green. No scope creep; no wire-format or model changes.

## Issues Encountered

- The KEY-04 panel widget test initially recorded zero sends: the arrow cluster laid out at y=594–642, just past the 600px test viewport, so the synthetic gesture hit nothing (flutter_test only warns on `tap`, not `startGesture`). Diagnosed with a temporary probe test; fixed with `tester.ensureVisible` plus stable `ValueKey('cap-<code>')` cap keys.

## Known Stubs

None — all rows, chips, and emission paths are fully wired to the live reliable channel; nothing renders placeholder data.

## Threat Flags

None — no new surface beyond the plan's threat model: all KeyMsg traffic rides the auth-gated `sendReliable`, gated UI renders inert, no packages added.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- ROADMAP Phase-4 criteria 3, 4, 5 are now user-operable in code: toggleable F/numpad/nav rows, glanceable sticky modifiers with combos + auto-reset, server-side hold autorepeat stopping on release
- Remaining phase work is the end-of-phase on-device gate (04-VALIDATION Manual-Only): nav/fn/num keys act on the PC; Win+D and Ctrl+Alt+Del combos; hold-arrow autorepeat + instant stop; mid-combo disconnect leaves nothing held
- Phase 5 (control center) can reuse the same KeyMsg vocabulary and the ModifierFsm effects pattern for key macros

---
*Phase: 04-trackpad-keyboard*
*Completed: 2026-07-09*

## Self-Check: PASSED

All 6 created/modified key files exist on disk; all 4 task commits (e9f4259, 957de54, a5765fb, e647ce5) present in git log.
