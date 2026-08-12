---
phase: quick-260809-ipc
plan: 01
status: complete
subsystem: ui
tags: [flutter, riverpod, keyboard, trackpad, mediaquery, shared-preferences]

requires:
  - phase: 04-trackpad-and-keyboard
    provides: the D-07 docked panel, ModifierFsm, KeyCap, the CR-01/CR-02/IN-04/D-10/D-11/D-12 contracts
  - phase: 10-keyboard-rethink
    provides: the four pads, KeyboardTabBar, capsForPad, keyboard.pad persistence, KeyboardScreen
provides:
  - KeyboardInputController — the single owner of the stuck-key model, shared by both keyboard surfaces
  - the trackpad-docked panel rebuilt as the same swipeable four-pad deck (Type | Arrows | Numpad | Fn)
  - the docked-panel sizing contract (kPanelPadHeights, kPanelChromeHeight, kPanelColumnOverhead, panelPadHeight)
  - keyboard.panelPad persistence on the KeyboardPad model, with a one-time migration of the retired key
  - deletion of the row-group surface — no second keyboard vocabulary remains in lib/
affects: [keyboard, trackpad, any future third keyboard surface]

tech-stack:
  added: []
  patterns:
    - "Plain-object controller for shared lifecycle-owned logic (ModifierFsm / TrackpadDriver house shape)"
    - "MediaQueryData.fromView(View.of(context)) + didChangeMetrics for raw window metrics under a stripping Scaffold/SafeArea"
    - "One typed store parameterised by prefs key = one model, two mount points"

key-files:
  created:
    - app/remote_control/lib/keyboard/keyboard_input_controller.dart
    - app/remote_control/test/keyboard/keyboard_input_controller_test.dart
  modified:
    - app/remote_control/lib/keyboard/keyboard_panel.dart
    - app/remote_control/lib/keyboard/keyboard_screen.dart
    - app/remote_control/lib/keyboard/key_pads.dart
    - app/remote_control/lib/keyboard/key_rows.dart
    - app/remote_control/test/keyboard/keyboard_panel_test.dart
    - app/remote_control/test/keyboard/key_pads_test.dart
    - app/remote_control/test/keyboard/key_pads_store_test.dart
    - app/remote_control/test/keyboard/key_rows_test.dart
    - app/remote_control/test/keyboard/pad_widgets_test.dart
    - app/remote_control/test/trackpad/trackpad_screen_test.dart

key-decisions:
  - "The shared owner is a plain Dart object constructed and disposed by each surface — not a State mixin, not a lifted holder"
  - "Persistence: SEPARATE prefs keys (keyboard.pad / keyboard.panelPad), ONE model (KeyboardPad)"
  - "The retired preference is migrated on the panel store's first load and survives only as a private literal"
  - "Paging glue stays duplicated per surface; extract KeyboardPadDeck only if a THIRD surface appears"
  - "The clamp subtracts kPanelColumnOverhead (122), not kPanelChromeHeight (121): the always-mounted 1px hidden IME sliver is a real column consumer"
  - "panelPadHeight clamps as min(request, max(floor, ceiling)) — the floor lifts the ceiling, never the pad's own request"

patterns-established:
  - "Inset-discriminating tests: assert a floor COMPUTED from driven view metrics, on viewports where the naive MediaQuery read gives a different answer"
  - "A restore jump that outlives an unmounted deck: hold the pending pad, apply when the deck appears"

requirements-completed: [QUICK-260809-ipc-unify-docked-keyboard-panel]

duration: ~2h
completed: 2026-08-09
---

# Quick 260809-ipc: Unify the trackpad-docked keyboard panel — Summary

**The app now ships ONE keyboard at two mount points: the trackpad-docked panel
became the same swipeable four-pad deck as the full-screen keyboard, both drive
a single `KeyboardInputController` that owns the stuck-key model, and the
row-group surface is gone from `lib/` — key, widgets, and comments.**

## Performance

- **Tasks:** 4 of 4, one atomic commit each
- **Files modified:** 12 (2 created, 10 modified)
- **`flutter test`:** 832 → **863**, all green
- **`flutter analyze`:** clean at every task boundary

## Commits

| Task | Commit | What |
|---|---|---|
| 1 | `5c544f5` | `KeyboardInputController` + its surface-free suite; both surfaces rewired; 4 new panel tests |
| 2 | `af8dec4` | the sizing contract in `key_pads.dart`, `TypePad(showHint:)`, `kPanelPadPrefsKey` + the migration |
| 3 | `9838bdf` | the panel rebuilt as the four-pad deck; the B2 regression guards |
| 4 | `da105c6` | the row-group surface deleted, comments included; tests pruned and re-homed |

## 1. The shared owner, and the test that proves dispose timing on EACH surface

**Abstraction chosen: a plain Dart object**, `KeyboardInputController`, with
four injected seams (`send`, `changes`, `isDisconnected`, `onChanged`),
constructed in each surface's `initState` and disposed from each surface's own
`dispose()`.

This preserves dispose *timing* by construction — nothing changed about WHEN
`dispose()` runs, only WHERE the flush lives — and, unlike a `State` mixin, it
is directly unit-testable with no widget at all. That is the point: before this
change every sacred invariant could only ever be asserted through two widget
harnesses, which is the disease, not the cure.

| Surface | Test that proves dispose timing | Status |
|---|---|---|
| Owner, surface-free | `dispose on a LIVE socket flushes owed ups then releaseAll(), in that order` + `dispose on a DISCONNECTED socket sends NOTHING` | NEW (Task 1) |
| `KeyboardScreen` (route pop) | `screen-dispose LIVE flush: a held cap AND a locked modifier both get their ups…` + `screen-dispose on a DISCONNECTED socket: NO sends` | pre-existing, **body untouched**, green |
| `KeyboardPanel` (docked child unmount) | `panel-dispose LIVE flush…` + `panel-dispose on a DISCONNECTED socket sends NOTHING` | NEW (Task 1) — this surface had neither |
| `KeyboardPanel` (collapse, not unmount) | `collapsing the panel mid-hold releases the held key exactly once` | NEW (Task 1) — a shipped path with no coverage at all |
| Pad / page leave | `CR-01: a cap held across a PAGE LEAVE releases` (screen); `CR-01: a pad disposed mid-hold releases its held key` (pads) | pre-existing, green |

`grep -c "ModifierFsm()"` across `lib/keyboard/*.dart` is **1** — the FSM is
constructed in exactly one place. `IN-04` is now proven on the owner, on the
screen (pre-existing) and on the panel (new cancelled-press test).

The collapse behavior was preserved verbatim per `<out_of_scope>`: the new test
pins the CAP half only. See "Observations" below for the modifier half.

## 2. Persistence: separate keys, one model

`keyboard.pad` stays the full-screen keyboard's; the panel writes the NEW
`keyboard.panelPad`. Both hold `KeyboardPad` enum names through one
`KeyboardPadStore` parameterised by `key`. `KeyRowGroup` and its public prefs
key are deleted.

**Migration table** (one-time read when `keyboard.panelPad` is unset; the mapped
value is written back immediately, so the legacy read never happens twice):

| Retired value | New pad | Why |
|---|---|---|
| `fn` | `KeyboardPad.fn` | a deliberate choice with an exact successor |
| `num` | `KeyboardPad.numpad` | same |
| `nav` / unset / unknown / read throws | `KeyboardPad.type` | `nav` was the default nobody chose and its caps split across Type and Arrows; the slim Type strip is the least disruptive first open |

All five inputs round-trip in `key_pads_store_test.dart`, which pins the legacy
literal **by hand** so the migration cannot drift. `grep -rc "keyboard.rowGroup"
app/remote_control/lib` is **1** — the private literal inside the migration,
and nowhere else.

## 3. The column height as shipped, and the naive-formula experiment

```dart
final view = MediaQueryData.fromView(View.of(context));
final columnHeight = view.size.height -
    view.viewPadding.top -
    math.max(view.viewPadding.bottom, view.viewInsets.bottom);
```

plus `with WidgetsBindingObserver` and
`didChangeMetrics() => if (mounted) setState(() {})` — both halves are
required, and the reason is spelled out in a comment at the call site naming
`Scaffold.removeViewInsets` and `SafeArea`'s `removePadding`.

**The by-hand experiment was performed.** Swapping in the naive
`sizeOf/paddingOf/viewInsetsOf` form and re-running `test/trackpad/`:

| Case | Correct | Naive | Floor | Result |
|---|---|---|---|---|
| 1 — 411×891, insets 24/48, IME down, Numpad | 321 | 321 | 304.55 | **green both ways** (not a discriminator, exactly as predicted) |
| 2 — 411×891, IME still raised 290dp, Numpad | 195.65 | **79.0** | 195.65 | **RED under naive** |
| 3 — 360×640, insets 24/24, Numpad | 202.4 | **176.0** | 202.4 | **RED under naive** |

The correct formula was then restored and both went green again.
`grep -c "MediaQueryData.fromView" keyboard_panel.dart` is 1.

## 4. Measured heights, next to the planned numbers

Panel totals measured directly off the rendered `AnimatedSize` at
`columnHeight = 843` (the reference device, nothing clamped):

| Pad | Planned viewport | **Measured panel** | Planned panel |
|---|---|---|---|
| Type | 80 | **201** | 201 |
| Arrows | 272 | **393** | 393 |
| Fn | 304 | **425** | 425 |
| Numpad | 312 | **433** | 433 |

Trackpad remainder on the three driven viewports. **Bold = measured in
`trackpad_screen_test.dart`**; the rest are computed from the same pure
`panelPadHeight` those measurements validate (its clamp, floor and guarantee
are separately pinned by a 98-column sweep in `key_pads_test.dart`).

| Viewport (column) | Pad | Panel cost | Trackpad | Planned trackpad |
|---|---|---|---|---|
| **1.** 411×891, 24/48, IME down (819) | Type | 202 | 553 | — |
| | Arrows | 394 | 361 | — |
| | Fn | 426 | 329 | — |
| | Numpad | 434 | **321** | 322 (±1) |
| **2.** 411×891, IME 290dp (577) | Type | 202 | 311 | 312 |
| | Arrows | 317.35 | 195.65 | — |
| | Fn | 317.35 | 195.65 | — |
| | Numpad | 317.35 | **195.65** | 195.65 |
| **3.** 360×640, 24/24 (592) | Type | 202 | 326 | — |
| | Arrows | 325.6 | 202.4 | — |
| | Fn | 325.6 | 202.4 | — |
| | Numpad | 325.6 | **202.4** | 202.4 |

Every clamped trackpad figure matches the plan **exactly**. Case 1's Numpad is
321 against a planned 322 — see deviation 3, and note the plan's own tolerance
was ±1.

Case 1 also proves the trackpad is *usable*, not merely present: a real drag on
the 321dp surface with the tallest pad open produces a non-empty
`service.moves`.

## 5. `flutter test` delta: 832 → 863 (+31), line by line

| File | Before | After | Δ | Why |
|---|---|---|---|---|
| `keyboard_input_controller_test.dart` | 0 | 10 | **+10** | the sacred invariants proven once, on the owner, with no widget |
| `keyboard_panel_test.dart` | 13 | 22 | **+9** | +4 dispose/IN-04/collapse (Task 1), +5 height/animation/IME/persistence incl. the collapsed-mount open (Task 3). One existing test rewritten for the four-pad vocabulary; the other 12 bodies untouched |
| `key_pads_test.dart` | 9 | 15 | **+6** | +7 pure `panelPadHeight` tests, −1 (the deleted row-group cross-check) |
| `key_pads_store_test.dart` | 11 | 22 | **+11** | +11 panel-key + migration tests (5 legacy inputs, both-keys-present, throwing prefs, roundtrips, migration-off-by-default, key identity) |
| `key_rows_test.dart` | 11 | 2 | **−9** | the row-group switcher/persistence group and the key-cap emission group deleted (all proven on the pads in `pad_widgets_test.dart`), the duplicate vocabulary test deleted, the 48px floor **re-homed** |
| `pad_widgets_test.dart` | 16 | 17 | **+1** | `TypePad(showHint: false)` |
| `trackpad_screen_test.dart` | 1 | 4 | **+3** | the three B2 regression guards |
| **Total** | **832** | **863** | **+31** | |

No coverage was lost: every deleted assertion is either duplicated on the pads
at the lines the plan cited, or re-homed (the 48px touch-target floor, now a
bare `KeyCap` test under LOOSE constraints — the only place it can bind, since
inside a pad the `Expanded` cell's tight constraints win via
`BoxConstraints.enforce`).

## 6. `10-CONTEXT.md` line 15 is deliberately reversed

`10-CONTEXT.md` line 15 put the docked panel explicitly out of scope for the
phase-10 rethink, and 10-03 / 10-04 / 10-05 each carried an acceptance criterion
asserting `keyboard_panel.dart` stayed byte-unchanged. **That call is now
reversed on purpose**: the docked panel *was* the rethink's remaining gap, and
leaving it out is what produced two keyboards, two vocabularies, two
persistence keys and — worst — two copies of the stuck-key model. The planning
history is immutable and was not edited; this paragraph is the record.

## Deviations from Plan

### 1. [Rule 1 — Bug] The clamp formula contradicted the plan's own tables

- **Found during:** Task 2, writing the pure `panelPadHeight` tests.
- **Issue:** `<sizing_contract>` specifies
  `viewport = max(floor, min(request, ceiling))`. Because the 96px floor
  exceeds Type's 80px request, that form returns **96 for Type on every
  device**, making the Type panel 217 rather than the 201 the plan asserts in
  three places (the pad table, the reference-device table, and the required
  IME-raised test case).
- **Fix:** shipped as `min(request, max(floor, ceiling))` — the floor lifts the
  *ceiling*, never the pad's own request. The two forms agree for all three
  other pads; only Type differed. Reproduces every number in the plan's tables.
- **Files:** `key_pads.dart`; pinned by a dedicated test
  (`a pad never grows PAST its own request`).
- **Commit:** `af8dec4`

### 2. [Rule 1 — Bug] The restore jump could never land on this surface

- **Found during:** Task 3, wiring `panelPadProvider`.
- **Issue:** the plan ports the full-screen restore jump verbatim, and that
  version drops the jump when the `PageController` has no clients. The
  full-screen deck is mounted from its first frame, so this never bites there.
  The docked panel always mounts **collapsed** — `trackpad_screen.dart` mounts
  it inside a `ValueListenableBuilder` seeded `false` — so the async prefs load
  always lands with no `PageView` in the tree. The one-shot guard was consumed
  and the persisted pad became silently unreachable on **every real open**.
- **Fix:** the pad is held in `_pendingRestore` and applied the moment the deck
  exists (post-frame after expand). `didUpdateWidget` also consults the pending
  pad when deciding whether to raise the IME, so expanding onto a restored
  Numpad never raises the keyboard for a frame only to lower it.
- **Files:** `keyboard_panel.dart`; pinned by `persistence survives the REAL
  open path…`, which mounts collapsed, lets the load land, then expands.
- **Commit:** `9838bdf`

### 3. [Rule 1 — Bug] The 121px chrome omitted the hidden IME sliver

- **Found during:** Task 3, running the B2 guards — both discriminators missed
  their floor by **exactly 1.0**.
- **Issue:** `HiddenTextInput` is a 1×1 sliver mounted OUTSIDE the animating
  chrome (Pitfall 6), so it is invisible to a measurement of the panel's
  animating box — but it still costs the shared column a pixel, unconditionally.
  Subtracting only 121 in the clamp left the trackpad at 194.65 against a
  195.65 floor, and 201.4 against 202.4.
- **Fix:** `kPanelChromeHeight` stays **121** (the visible chrome the rendered
  panel measures, and the plan's stated constant); the clamp now subtracts a new
  `kPanelColumnOverhead` = **122**. This makes the plan's own *trackpad floor*
  numbers exact — strong evidence it is what the plan meant, since the plan
  derived those floors as `column − panel − 64` from panel totals that already
  implied the sliver.
- **Consequence, stated plainly:** unclamped panel *column cost* is now 1px
  more than the plan's table (Numpad 434, not 433). The rendered panel box is
  still exactly 433, which is what the panel tests measure and assert.
- **Files:** `key_pads.dart`, `key_pads_test.dart`.
- **Commit:** `9838bdf`

### 4. [Rule 3 — Blocking] Test harnesses had to model the real tree

Two harness changes, both making the tests *more* faithful, neither touching an
existing test body:

- `keyboard_panel_test.dart`'s host gained `resizeToAvoidBottomInset: true` +
  an outer `SafeArea`, mirroring `trackpad_screen.dart`. Without it
  `KeyboardTabBar`'s inner `SafeArea(top: false)` consumed the driven 24dp
  nav-bar inset and the chrome measured 145 instead of 121.
- `trackpad_screen_test.dart`'s pre-existing `_host()` gained a
  `panelPadStoreProvider` override. The panel now reads its persisted pad at
  *mount* rather than lazily on expand, and the real store constructs a
  `SharedPreferencesAsync`, which throws without a platform. Same precedent as
  `keyboard_screen_test.dart`'s `keyboardPadStoreProvider` override.

## Deferred Issues

Logged in
`.planning/quick/260809-ipc-unify-the-trackpad-docked-keyboard-panel/deferred-items.md`,
**not fixed** (SCOPE BOUNDARY — neither is caused by this task's changes):

1. **The modifier chip row overflows horizontally at 360dp width** by 7.3px —
   `ModifierChip`'s label Row, `Shift` at 16/w600 in a 74dp cell. The geometry
   is unchanged and shared: `KeyboardScreen._chipRow` (shipped 10-05) and the
   docked panel that shipped *before* this task have identical arithmetic, so
   both overflowed at 360dp already. It only became visible because no test had
   ever driven a 360dp-wide viewport with a chip row mounted. The 360×640 B2
   guard drains it explicitly, asserts every drained error is that one, and
   asserts the drain count is non-zero — so the day it is fixed, that test fails
   and points at the log entry. Fixing it touches BOTH surfaces and wants its
   own task.
2. **A locked modifier survives a panel COLLAPSE** — explicitly out of scope per
   the plan; shipped behavior preserved verbatim. Recorded because it is a real
   (if minor) stuck-input path: the caps unmount and release, but the panel
   State survives, so a LOCKED modifier stays physically held with no visible
   chip to un-lock until the panel is reopened.

## Observations

- The `<already_established>` claim that the three surviving
  `ensureVisible(find.byKey(ValueKey('cap-…')))` calls would resolve harmlessly
  against the new `PageView` **held** — all three tests pass with untouched
  bodies, as does every other pre-existing panel test.
- `keyboard_screen_test.dart` has a completely empty `git diff` across all four
  tasks, which is the auditable proof that Task 1's collapse was
  behavior-neutral on that surface.
- `trackpad_screen.dart` is **byte-unchanged** (`git diff --quiet` clean after
  every task), so the Pitfall-6 `ValueListenableBuilder` isolation cannot have
  regressed.

## Threat Flags

None. No new network endpoint, auth path, file access pattern or schema at a
trust boundary. `kClientKeyCodes` is untouched (T-IPC-06 `accept` holds), no
package was installed (T-IPC-SC `accept` holds), and no `server/`, `extension/`
or `protocol/` file appears in any commit of this plan.

## Known Stubs

None. No hardcoded empty collections, placeholder copy or unwired components
were introduced; every surface in this change is backed by real data.

## Self-Check: PASSED

All created files verified on disk; all four task commits verified in `git log`.
Working tree carries no uncommitted code changes — only the untracked planning
directory, which the orchestrator owns.
