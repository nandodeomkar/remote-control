---
phase: 04-trackpad-keyboard
plan: 07
subsystem: keyboard
tags: [flutter, keyboard, ime, diff-ops, disconnect-hygiene, security, tdd]

# Dependency graph
requires:
  - phase: 04-trackpad-keyboard (04-05)
    provides: HiddenTextInput + ImeDiffProducer sentinel model (kImeSentinel, _reseeding guard, reseed/needsReseed)
  - phase: 04-trackpad-keyboard (04-06)
    provides: KeyboardPanel D-12 disconnected-transition detection (_onDisconnected off the changes ping stream)
provides:
  - Atomic producer+controller IME reset on the disconnected transition (CR-01 closed)
  - HiddenTextInput.resetSignal Listenable seam (optional ctor param, didUpdateWidget re-subscription, guarded write-back)
  - KeyboardPanel._imeResetTick ValueNotifier fired in _onDisconnected, wired as resetSignal
  - Two CR-01 regression tests locking no-replay + backspace-is-bs post-reconnect
affects: [04-08, phase-04-verification, 04-SECURITY re-audit, phase-07-settings]

# Tech tracking
tech-stack:
  added: []
  patterns: [owner-fired Listenable reset seam answered by a guarded synchronous producer.reseed() write-back]

key-files:
  created: []
  modified:
    - app/remote_control/lib/keyboard/hidden_text_input.dart
    - app/remote_control/lib/keyboard/keyboard_panel.dart
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/test/keyboard/keyboard_panel_test.dart

key-decisions:
  - "CR-01 fixed via verification option 2 (atomic both-sides wipe) over option 1 (delete the reset): the wipe also purges pre-disconnect plaintext (possibly a password) from the controller buffer — the stronger T-04-03 closure"
  - "Reset seam is an optional Listenable? ctor param defaulting to null — every existing HiddenTextInput call site and test compiles unchanged"
  - "Panel remains the ONE disconnect detector: HiddenTextInput never subscribes to changes itself; it only answers the owner's signal"

patterns-established:
  - "External-reset seam: owner fires a ValueNotifier tick; the stateful child answers with producer.reseed() written back under the existing _reseeding guard — zero emissions, both sides sync in one synchronous callback"

requirements-completed: [KEY-01]

# Metrics
duration: 6min
completed: 2026-07-10
---

# Phase 04 Plan 07: Atomic IME Reset on Disconnect Summary

**CR-01/T-04-03 closed: the disconnected transition now wipes the IME diff producer AND the hidden field's controller to kImeSentinel in one synchronous callback, so post-reconnect typing can never replay pre-disconnect text (possibly a password) through the reliable queue**

## Performance

- **Duration:** 6 min
- **Started:** 2026-07-10T04:54:25Z
- **Completed:** 2026-07-10T05:00:25Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Closed verification gap CR-01 (04-VERIFICATION gap 1, roadmap SC2 / KEY-01): the old one-sided `_imeProducer.reset()` in trackpad_screen desynced the diff baseline from the controller text — the first post-reconnect keystroke replayed ALL pre-disconnect typing and a backspace became an insert. Both sides now reset atomically.
- Closed security threat T-04-03 (Information Disclosure): pre-disconnect plaintext is purged from BOTH the diff baseline and the controller buffer on the D-12 transition — ready for `/gsd-secure-phase 4` re-audit sign-off.
- `HiddenTextInput` gained an optional `resetSignal` Listenable seam: `_onExternalReset` writes `producer.reseed()` back into the controller under the existing `_reseeding` guard (zero emissions); `didUpdateWidget` re-subscribes on signal identity change (IN-05-class hazard avoided); listener removed before controller dispose.
- `KeyboardPanel` fires `_imeResetTick` inside `_onDisconnected` — the panel stays the single disconnect detector (one detector, one truth).
- Two CR-01 regression tests lock the contract executable: no-replay (first post-reconnect keystroke emits only the new char) and backspace-stays-a-backspace (bs:1, never an insert; boundary reseed still restores the full sentinel).

## Task Commits

Each task was committed atomically (Task 1 was TDD — RED then GREEN):

1. **Task 1 (RED): CR-01 regression tests, failing against the desync** - `76ebb93` (test)
2. **Task 1 (GREEN): atomic producer+controller IME reset seam** - `43dcc3a` (feat)
3. **Task 2: CR-01 regression tests — no replay, backspace stays a backspace** - artifact landed in the `76ebb93` RED commit per TDD flow; verification (full suite + analyze) ran green with no further changes

_No REFACTOR commit — GREEN needed no cleanup._

## Files Created/Modified

- `app/remote_control/lib/keyboard/hidden_text_input.dart` - `resetSignal` ctor param + field, `_onExternalReset` guarded write-back, `didUpdateWidget` re-subscription, dispose-order fix (listener removed before controller dispose)
- `app/remote_control/lib/keyboard/keyboard_panel.dart` - `_imeResetTick` ValueNotifier field (doc'd as the CR-01 wipe trigger), fired in `_onDisconnected`, disposed in `dispose`, wired as `resetSignal`; class doc D-12 section updated
- `app/remote_control/lib/trackpad/trackpad_screen.dart` - one-sided producer reset deleted from the changes listener (`_driver.reset()` untouched); comment rewritten to point at the panel-owned atomic hygiene
- `app/remote_control/test/keyboard/keyboard_panel_test.dart` - two CR-01 regression testWidgets using the existing host() harness (no harness changes — resetSignal is internal to the panel)

## Decisions Made

- Verification option 2 (atomic both-sides wipe) over option 1 (delete the reset, leave text in the buffer): option 2 also purges the pre-disconnect plaintext from the controller — the stronger T-04-03 closure — and its regression tests fit the existing keyboard_panel_test fake-changes-stream harness.
- The reconnect (true→false) transition intentionally fires NO reset — only the false→true transition wipes; the test asserts zero emissions across both the wipe and the reconnect ping.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. RED failed at exactly the intended assertion (controller still held 'secret' after the drop); GREEN passed on the first run.

## Verification Results

- `flutter analyze` — No issues found
- `flutter test` — All 235 tests passed (233 pre-existing + 2 new; plan floor was >= 232)
- `grep -v '^\s*//' trackpad_screen.dart | grep -c "_imeProducer.reset"` → 0 (one-sided reset gone from code)
- Acceptance greps: `resetSignal` x7, `_onExternalReset` x5, `didUpdateWidget` x2 (hidden_text_input.dart); `_imeResetTick` x4 (keyboard_panel.dart); `_driver.reset()` x1 (trackpad_screen.dart); `CR-01` x2 (keyboard_panel_test.dart)

## Threat Register Outcome

- **T-04-03 (Information Disclosure)** — mitigated as planned: atomic sentinel reset purges typed text from diff baseline + controller buffer; regression tests lock no-replay + bs-not-insert; existing redaction (no typed-text logging, ExcludeSemantics) untouched. Re-run `/gsd-secure-phase 4` to flip it to closed.
- **T-04-SC (Supply Chain)** — accepted as planned: zero new packages; pubspec.yaml and Cargo.toml untouched.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- CR-01 closed; 04-08 remains the only incomplete plan in phase 04.
- The end-of-phase human gate (04-VERIFICATION human_verification item 3 — IME fidelity on device) must re-run AFTER this fix so it exercises the corrected disconnect path.
- `/gsd-secure-phase 4` re-audit can now flip T-04-03 to closed.

---
*Phase: 04-trackpad-keyboard*
*Completed: 2026-07-10*

## Self-Check: PASSED

All modified files present on disk; task commits 76ebb93 (test) and 43dcc3a (feat) verified in git log.
