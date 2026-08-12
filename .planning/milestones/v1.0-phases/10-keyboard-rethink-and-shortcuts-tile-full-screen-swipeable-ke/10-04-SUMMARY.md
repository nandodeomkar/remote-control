---
phase: 10-keyboard-rethink-and-shortcuts-tile
plan: 04
subsystem: client-keyboard
tags: [keyboard, pads, widgets, layout, tab-bar]
requires:
  - KeyCap / KeyCapDef (10-03 public shared cap)
  - kTypeExtrasCaps / kArrowsTopCaps / kFnEscCap / kNavArrowCaps / kNumCaps / kFnCaps
  - KeyboardPad enum + capsForPad (10-03 vocabulary seam)
  - tokens.dart (kBg / kAccent / kMuted / kHairline)
provides:
  - TypePad / ArrowsPad / NumpadPad / FnPad (the four full-screen pads)
  - KeyboardTabBar + kKeyboardTabLabels + kKeyboardTabIcons
  - kKeyboardHint (moved here — TypePad owns it)
  - KeyCap layout/typography seams (minWidth / padding / labelSize / labelWeight / iconSize)
affects:
  - 10-05 (keyboard screen — mounts the pads in a PageView, binds keyboardPadProvider to KeyboardTabBar)
tech-stack:
  added: []
  patterns:
    - "Private abstract _KeyPad base holds the shared callback contract + the one cap() factory — four public pads, zero duplicated press logic"
    - "Additive-with-safe-defaults widget seams: every new KeyCap param defaults to today's behavior, so existing call sites and finders are untouched"
key-files:
  created:
    - app/remote_control/lib/keyboard/key_pads.dart
    - app/remote_control/test/keyboard/pad_widgets_test.dart
  modified:
    - app/remote_control/lib/keyboard/key_rows.dart
    - app/remote_control/lib/keyboard/keyboard_screen.dart
decisions:
  - "padding — not minWidth — is the seam that actually relaxes the Type row: under an Expanded cell BoxConstraints.enforce already clamps the 48px floor to the parent's tight width, so minWidth is inert there. minWidth still ships (UI-SPEC names it, and it DOES bind under the docked panel's loose Wrap constraints), but the 12px→4px padding relaxation is what stops a ~40dp cap clipping 'Esc'"
  - "KeyCap's 48px HEIGHT floor stays hard-coded and unparameterized — UI-SPEC relaxes width only ('Height stays >=48dp'), and the height floor is what actually keeps a cap tappable"
  - "kKeyboardHint MOVED (not copied) to key_pads.dart; keyboard_screen.dart imports it. A duplicate const would have made 10-05 unable to import both files without an ambiguous-name collision"
  - "KeyboardTabBar runs no haptic and no page animation — the screen owner does both on onSelect, so swipe-settle can reuse the selection path without double-firing a haptic (UI-SPEC: no extra haptic on settle)"
  - "Arrows inverted-T is width-capped via Center + ConstrainedBox(maxWidth: 304) around the cluster, not per-cap: a tight Expanded parent wins over any per-cap maxWidth via enforce(), so the cap must be applied where constraints are still loose"
metrics:
  duration: ~14min
  tasks: 2
  files: 4
  completed: 2026-07-17
---

# Phase 10 Plan 04: Full-Screen Keyboard Pads + Tab Bar Summary

Built the four finger-sized pads (Type/Arrows/Numpad/Fn) and the bottom tab bar as service-agnostic widgets over the shared `KeyCap`, adding the layout/typography seams 10-03 deliberately deferred — all additive, all defaulting to today's behavior.

## What Shipped

**Task 1 — the four pads + the KeyCap seams** (`bc36db3`)
- `lib/keyboard/key_pads.dart`: `TypePad` (hint canvas + 7-cap slim extras row), `ArrowsPad` (Home/End/PgUp/PgDn row + large inverted-T), `NumpadPad` (calculator grid + full-height Enter), `FnPad` (full-width Esc + F1–F12 grid). Caps size by `Expanded` flex and fill the pad height.
- A private `abstract _KeyPad` base carries the six-field `KeyRows` callback contract and the single `cap()` factory, so all four pads mount the same shared `KeyCap` and none re-implements press logic.
- `KeyCap` gained five additive params: `minWidth` (48), `padding` (12px h), `labelSize` (14), `labelWeight` (w400), `iconSize` (20). Every default is today's exact value.
- `kKeyboardHint` moved here verbatim with its grandfathered `#4A505C` / 13/400 face; `keyboard_screen.dart` now imports it.

**Task 2 — KeyboardTabBar** (`5257bf8`)
- 56px `kBg` bar + bottom `SafeArea`, 4 equal tabs, icon 24 over label 12/400 with a 4px gap.
- Selected: `kAccent` icon + label + a 2px `kAccent` top-edge border replacing that tab's 1px `kHairline` segment (so the bar's hairline top border reads continuous except at the selection).
- `kKeyboardTabLabels` / `kKeyboardTabIcons` as named const maps. All four UI-SPEC glyphs (`keyboard`/`open_with`/`dialpad`/`function`_rounded) verified present in the pinned `material_symbols_icons` 4.2951.0 — **no substitution needed**.

## Sacred-Surface Compliance

| Constraint | Evidence |
|---|---|
| `KeyCap` emission logic byte-untouched | `key_rows.dart` diff removes exactly 6 lines: 1 doc line + 5 hard-coded style/constraint values swapped for the new params. Zero lines inside `_onTapDown`/`_onTapUp`/`_onTapCancel`/`dispose` changed |
| Docked `KeyboardPanel` (D-07) untouched | `keyboard_panel.dart` in no commit; its suite green unchanged |
| `keyboard.rowGroup` untouched | Not referenced by this plan; `KeyRowGroupStore`/`KeyRowGroupSwitcher` byte-identical |
| Existing `KeyRows` call sites unchanged | Every new param has a default = the old literal; `KeyRows._cap` is untouched and all pre-existing cap finders still resolve (46 pre-existing keyboard tests green) |
| No screen wiring started | No `PageView`, no FSM lift, no screen edit beyond the hint import — pads take injected callbacks only |
| No keep-alive | `grep -n "AutomaticKeepAlive\|keepAlive\|wantKeepAlive" key_pads.dart` → empty (the doc comment warning against it is worded to avoid the token, keeping the gate literal) |

## The two seams 10-03 flagged — how they were designed

**Typography seam** — straightforward: `labelSize`/`labelWeight`/`iconSize` params. Pads pass 16/600 (large caps), 28/400 (numpad digits), 28px (inverted-T arrows); defaults keep the docked rows at 14/400 + 20px.

**minWidth seam** — the interesting one. The handoff predicted the 48px `minWidth` floor would "fight" 7 `Expanded` caps on a <392px phone. Tracing `RenderConstrainedBox.performLayout` → `_additionalConstraints.enforce(constraints)` shows it does **not** fight: under an `Expanded` cell the incoming width is tight, and `enforce` clamps the 48px floor down to it. The floor is silently inert there — no overflow was ever possible.

The real squeeze is the cap's own **12px horizontal padding**: at ~40dp wide that leaves 16px for a 25px-wide `Esc`. So `padding` is the seam doing the work (Type row passes 4px), and it is documented as such at the declaration. `minWidth` still ships because UI-SPEC names the relaxation explicitly and because it genuinely binds where caps sit under *loose* constraints — the docked panel's `Wrap`. Both are honest; neither is a magic constant.

## Verification

- `flutter test test/keyboard/pad_widgets_test.dart` — **16 passed** (11 pad, 5 tab bar).
- `flutter test test/keyboard/` — **76 passed** (65 pre-existing + 11 new at Task 1).
- `flutter test` (full app) — **529 passed** (513 pre-existing + 16 new).
- `flutter analyze` — **No issues found** (whole package).
- `grep -n "Icons\." key_pads.dart` → empty; only `#4A505C` (grandfathered) as a raw hex.

Beyond the plan's asks, the suite also pins two stuck-key invariants at the pad level: **IN-04** (mid-press gate flip still fires the up) and **CR-01** (a pad disposed mid-hold releases its held key — the test that would fail the moment someone adds a keep-alive).

## Deviations from Plan

**1. [Rule 3 - Blocking] `keyboard_screen.dart` edited to complete the hint MOVE**
- **Found during:** Task 1
- **Issue:** The plan's `files_modified` lists only `key_pads.dart` + the test, but its artifact table says `kKeyboardHint` is **moved** here. Declaring it in `key_pads.dart` while leaving the original would duplicate the copy literal (against the house "one named const" rule) and — the blocking part — leave 10-05 unable to import both `key_pads.dart` and `keyboard_screen.dart` (for `kKeyboardTitle`) without an ambiguous-name collision.
- **Fix:** Removed the declaration from `keyboard_screen.dart` and imported it from `key_pads.dart`. The screen's private `_kKeyboardHintColor` stays local (the pads' copy is private to `key_pads.dart`); 10-05 retires that screen body anyway.
- **Files modified:** `app/remote_control/lib/keyboard/keyboard_screen.dart` (6 lines)
- **Commit:** `bc36db3`

**2. [Rule 3 - Blocking] `key_rows.dart` modified to add the KeyCap seams**
- **Found during:** Task 1
- **Issue:** Also not in `files_modified`, but the pads cannot meet UI-SPEC's faces (16/600, 28/400 digits, 28px arrows) or the Type-row relaxation against a `KeyCap` with hard-coded 14/400 + 20px + 12px padding. The executor prompt's `inherited_context` explicitly assigns this seam design to 10-04.
- **Fix:** Five additive params, all defaulting to the previous literals. See the Sacred-Surface table for the byte-untouched evidence.
- **Files modified:** `app/remote_control/lib/keyboard/key_rows.dart`
- **Commit:** `bc36db3`

No other deviations — no bugs found, no architectural questions raised, no auth gates hit.

## Notes for 10-05

- **Mount contract:** each pad takes exactly the `KeyRows` six: `enabled`, `onKeyDown`, `onKeyUp`, `onKeyTapWithMods`, `hasArmedMods`, `onPressHaptic`. Drop them into the `PageView` with `allowImplicitScrolling: false` and **no keep-alive** — `pad_widgets_test.dart`'s CR-01 test fails if that regresses.
- **PageView order** is `KeyboardPad.values` order (type, arrows, numpad, fn) — the same order `KeyboardTabBar` renders and `keyboardPadProvider` persists, so `KeyboardPad.values.indexOf(pad)` is the page index. No separate mapping table is needed.
- **The tab bar deliberately does nothing but report.** `onSelect` must do all three of: `hapticTick()`, `pageController.animateToPage(200ms, ease)`, and `ref.read(keyboardPadProvider.notifier).set(pad)`. On *swipe* settle, `onPageChanged` should do the `set(...)` **without** a haptic (UI-SPEC).
- **Re-tapping the current tab still fires `onSelect`** (pinned by test). If a same-page select should be a no-op, guard it in the screen.
- **IME:** `TypePad` renders the hint + extras row only. `HiddenTextInput` is the screen's job, mounted **outside** the PageView (UI-SPEC §Structure, Pitfall 6). The pad has no focus node and doesn't want one.
- **Modifier chips are not here** — they're screen-level and persistent across all four pads, so `hasArmedMods` will close over the screen's single `ModifierFsm`.
- The pads have no production caller yet **by design**; every one is exercised by widget tests.

## Known Stubs

None — all four pads and the tab bar are fully implemented and tested. Their production mount point is 10-05 (the plan's explicit scope boundary), not a stub.

## Threat Flags

None. Client-only widget layout; no network surface, no protocol change, no new package. T-10-05 (stuck input) is mitigated by construction — every cap is the shared `KeyCap`, no keep-alive exists, and IN-04/CR-01 are now pinned by pad-level tests rather than by inspection.

## Self-Check: PASSED

- FOUND: `app/remote_control/lib/keyboard/key_pads.dart` (contains `class KeyboardTabBar`, `KeyCap(`, `onSelect`)
- FOUND: `app/remote_control/test/keyboard/pad_widgets_test.dart`
- FOUND: commit `bc36db3` (Task 1)
- FOUND: commit `5257bf8` (Task 2)
