---
phase: 04-trackpad-keyboard
plan: 05
subsystem: ui
tags: [flutter, keyboard, ime, diff-ops, text-input, trackpad]

# Dependency graph
requires:
  - phase: 04-02
    provides: real type_text/backspace Windows executors the text frames land on
  - phase: 04-04
    provides: grown trackpad screen (Column layout, bottom-right cluster, disconnect-hygiene subscription, panel-toggle visual pattern)
  - phase: 01 (remote_protocol)
    provides: computeDiff (grapheme-cluster-exact, fixture-proven) + TextMsg codec
provides:
  - ImeDiffProducer — committed-text diffing with the ZWSP sentinel model (KEY-01, D-08)
  - kImeSentinel (8 x U+200B, explicit escapes) so boundary backspaces keep emitting bs frames
  - HiddenTextInput — zero-footprint IME-attached TextField (never Offstage; input connection survives)
  - KeyboardPanel shell (D-07) with the always-mounted hidden input and the 04-06 rows slot
  - Panel toggle (Icons.keyboard/keyboard_hide) in the trackpad screen's bottom-right cluster
affects: [04-06, keyboard, trackpad]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sentinel-seeded hidden field: invisible ZWSP prefix keeps the TextField non-empty so backspace-at-boundary still fires onChanged; reseed write-back is guarded and never emits"
    - "Always-mounted-input panel: the IME field lives OUTSIDE the AnimatedSize chrome so expand/collapse never detaches the Android input connection"
    - "Panel state on a ValueNotifier wrapping ONLY the panel slot and toggle icon — the Listener hot path keeps widget identity through panel animation (Pitfall 6)"

key-files:
  created:
    - app/remote_control/lib/keyboard/diff_ops.dart
    - app/remote_control/lib/keyboard/hidden_text_input.dart
    - app/remote_control/lib/keyboard/keyboard_panel.dart
    - app/remote_control/test/keyboard/ime_diff_producer_test.dart
    - app/remote_control/test/keyboard/keyboard_panel_test.dart
  modified:
    - app/remote_control/lib/trackpad/trackpad_screen.dart

key-decisions:
  - "IME-revision test follows fixture 02 semantics (bs:1, ins:'e ') — the plan's stated bs:3/'the ' contradicted both the fixture compute block and computeDiff's prefix walk, which the acceptance criteria lock as the only diff engine"
  - "kImeSentinel spelled as explicit \\u200B escapes, not literal ZWSPs — a literal run is invisible in source and un-greppable"
  - "HiddenTextInput sits as a 1x1 sibling ABOVE the AnimatedSize chrome inside KeyboardPanel — mounted in both states by construction, no maintainState tricks"
  - "IME Enter flows as ins '\\n' (multiline field) — enigo text() maps it to Return server-side; no client-side Enter special-casing"
  - "Disconnect hygiene extended: the existing ChipStatus.disconnected transition now also calls producer.reset() so stale committed text never skews the first post-reconnect diff"

patterns-established:
  - "lib/keyboard/ package: pure producer (no Flutter) + no-visual-contract widgets, mirroring the classifier/driver split in lib/trackpad/"

requirements-completed: [KEY-01]

# Metrics
duration: ~18min
completed: 2026-07-09
---

# Phase 4 Plan 05: Hidden-IME Typing + Keyboard Panel Shell Summary

**One-liner:** Phone-IME typing lands on the PC grapheme-exact — a sentinel-seeded hidden TextField feeds computeDiff into TextMsg on the reliable path, inside a 200ms keyboard panel docked over the still-live trackpad.

## What was built

### Task 1 — ImeDiffProducer (TDD)
`lib/keyboard/diff_ops.dart`, pure Dart (no Flutter imports). Tracks previous
committed text; `onChanged(next)` runs `computeDiff(_committed, next)` (the
remote_protocol fixture-proven engine — never re-implemented) and emits
`TextMsg(bs, ins)` only when non-empty. The sentinel model: the field always
starts with `kImeSentinel` (8 x U+200B, each its own grapheme cluster), so an
at-boundary backspace still shrinks the text and keeps `bs` frames flowing;
`needsReseed`/`reseed` restore the seed without emitting, `reset()` is the
disconnect/panel hygiene hook. Nine tests mirror the shared fixtures
(simple insert, IME revision, emoji single-grapheme, boundary backspace +
reseed, no-op, rapid backspace, reset).

### Task 2 — HiddenTextInput
`lib/keyboard/hidden_text_input.dart`: 1x1 logical px, Opacity 0,
IgnorePointer, ExcludeSemantics — focusable and IME-attached but never
visible. No Offstage/Visibility (Android input-connection detach, Pitfall 6).
Multiline keyboard (IME Enter -> '\n' as ins), autocorrect + suggestions ON
(D-08 rides the system IME), smart dashes/quotes disabled, no
cursor/selection/decoration. Reseed write-back sets a collapsed end selection
inside a re-entrancy guard.

### Task 3 — KeyboardPanel + screen wiring
`lib/keyboard/keyboard_panel.dart`: the hidden input mounted OUTSIDE a 200ms
ease AnimatedSize chrome (top hairline #2A2D34, md padding, bg #0E0F12
continuous with the trackpad, `rows` slot for 04-06). `expanded` flips drive
`imeFocusNode` focus/unfocus (raises/lowers the system IME).
`trackpad_screen.dart`: panel docked below the L/M/R bar (trackpad -> bar ->
panel -> system IME); keyboard toggle (48px circular, neutral, tooltips
"Show keys"/"Hide keys") joins the bottom-right cluster above the tune
affordance. Panel state is a plain `ValueNotifier<bool>` whose builders wrap
ONLY the panel slot and the toggle icon — the Expanded trackpad Stack keeps
its widget identity (zero `setState` in the file, hot path untouched).
`resizeToAvoidBottomInset: true` shrinks-but-never-hides the trackpad (D-07).

## Verification

- `flutter test` — 209 tests green (9 producer + 3 panel new).
- `flutter analyze` — no issues.
- Redaction gate: `grep -rn "print\|debugPrint" lib/keyboard/` matches only
  doc-comment prose ("prints", "footprint") — no logging of typed content
  (SPEC §12, T-04-03).
- `grep -v '^\s*//' lib/trackpad/trackpad_screen.dart | grep -c setState` = 0.
- On-device IME fidelity check (autocomplete revision, emoji, rapid
  backspace, live trackpad under the raised IME) deferred to the
  end-of-phase gate per the plan (04-VALIDATION Manual-Only, RESEARCH A2).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Plan's IME-revision test expectation contradicted the fixture and computeDiff**
- **Found during:** Task 1 (RED)
- **Issue:** The plan specified `sentinel+'thw' -> sentinel+'the '` emits
  `TextMsg(bs: 3, ins: 'the ')`, but the `02-ime-revision` fixture compute
  block and `computeDiff`'s common-prefix walk both give `bs = 3 - 2 = 1,
  ins = 'e '`. The acceptance criteria lock computeDiff as the only diff
  engine, making the plan's numbers unreachable.
- **Fix:** Test asserts the fixture-correct `TextMsg(bs: 1, ins: 'e ')`.
- **Files modified:** test/keyboard/ime_diff_producer_test.dart
- **Commit:** 2eba874

No other deviations — tasks otherwise executed as written.

## TDD Gate Compliance

Task 1 (`tdd="true"`): RED commit `2eba874` (tests fail — target absent),
GREEN commit `353d258` (all 9 pass). No refactor commit needed.

## Commits

| Task | Commit | Type |
|------|--------|------|
| 1 (RED) | 2eba874 | test |
| 1 (GREEN) | 353d258 | feat |
| 2 | 1811e6e | feat |
| 3 | e9fe62a | feat |

## Known Stubs

- `KeyboardPanel.rows` renders an empty `Column` placeholder — intentional
  per the plan; 04-06 fills it with modifier chips, the group switcher, and
  special-key rows (D-09/D-10).

## Next

04-06 builds the special-key rows + sticky modifiers inside this panel shell
(the `rows` slot), completing KEY-02/03/04.

## Self-Check: PASSED

All 5 created files exist on disk; all 4 task commits (2eba874, 353d258, 1811e6e, e9fe62a) present in git log.
