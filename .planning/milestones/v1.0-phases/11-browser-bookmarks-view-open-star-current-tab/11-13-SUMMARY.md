---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 13
subsystem: app
tags: [gesture-arena, flutter, bugfix, uat, d-13, d-14, spec-amendment, regression-tests]

# Dependency graph
requires:
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-09)
    provides: "_BmRow, confirmDestructive and the D-13/D-14 delete gate — the code this plan repairs"
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-12)
    provides: "11-UAT.md § Failure B — the on-device observation this plan exists to close (INPUT dependency only; zero files_modified overlap)"
provides:
  - "D-14's empty-folder delete reachable by a real gesture on real hardware — the phase's blocking defect, closed"
  - "D-13's link delete reachable without force-opening the bookmark first"
  - "_BmRowState._flash() / _activate() — the press-flash / side-effect split"
  - "7 regression tests at two layers, RED-proven against the pre-fix wiring"
  - "11-UI-SPEC.md's corrected gesture map + the _BmRow vs _TabRow divergence rule — the ROOT-CAUSE fix"
affects: [phase-close, 11-UI-SPEC, deferred-items]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Split the visual press feedback from the side-effectful action: flash on onTapDown, act on onTap, whenever the action replaces or removes the row"
    - "RED-prove a regression test by reverting the fix and asserting an EXACT failure count, then restoring byte-identically — a test that cannot fail against the old code proves nothing"
    - "When a widget test and a device disagree, suspect the test's FIXTURE, not just its assertions: a recorded callback that swaps nothing cannot reproduce a defect caused by the swap"

key-files:
  - app/remote_control/lib/browser/bookmarks_section.dart
  - app/remote_control/test/browser/bookmarks_section_test.dart
  - app/remote_control/test/browser/browser_screen_test.dart
  - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-UI-SPEC.md
  - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-VALIDATION.md
  - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-UAT.md
---

# Plan 11-13 — Close UAT-8 / Failure B

**Status: COMPLETE. 4/4 tasks. UAT-8 re-run PASSED on device 2026-07-31.**

## What was wrong

`_BmRow` wired the accent flash, the drill-in/open action and the delete confirm onto one `InkWell`,
with the action on `onTapDown`. `BaseTapGestureRecognizer.didExceedDeadline()` calls `_checkDown()`,
so `onTapDown` fires at `kPressTimeout` (100 ms) whether or not the tap won the arena, while
`LongPressGestureRecognizer` sets `deadline: kLongPressTimeout` (500 ms) and only then resolves.
Every long press therefore ran the tap-down action 400 ms before the long press could land.

- **Folder rows:** the drill-in replaced the list, destroying the pressed row. D-14's empty-folder
  delete was unreachable by any gesture — confirmed with `count == 0`, where `isDeletable` is true
  and `onLongPress` IS wired.
- **Link rows:** the delete landed, but only after `bm.open` had fired — deleting a bookmark
  force-opened it in a PC tab first.

`_TabRow` was unaffected and stayed byte-untouched: activating a tab does not destroy the row, so its
long-press close still resolves.

## Commits

| Commit | Task | What |
|--------|------|------|
| `a5cd678` | 1 | `_fire()` → `_flash()` (onTapDown, visual only) + `_activate()` (onTap, the side effect); `kBmDeleteHint` gains the empty-folder case |
| `adb8413` | 2 | 7 regression tests across two layers + the RED proof |
| `7723602` | 3 | `11-UI-SPEC.md` gesture map amended (the root cause) + `11-VALIDATION.md` counts |
| `798cc78` | — | STATE checkpoint before the human gate |
| _(this)_ | 4 | UAT-8 re-run recorded in `11-UAT.md`; deferred item 4 logged |

## The root cause was the SPEC, not the code

`11-UI-SPEC.md`'s Interaction / Gesture Map specified `tap-down: drill in + flash + haptic` **and**
`long-press: confirm → delete` on the same folder row. Those are mutually exclusive by construction.
Plan 11-09 implemented the contradiction faithfully. Fixing only the Dart would have left a future
executor to re-derive the same defect from the same document.

The spec now carries the rule: **a row whose tap action REPLACES or REMOVES the row must fire on
`onTap`, never on `onTapDown`.** The highest-leverage edit was the `List row` idiom cell (~line 36) —
the sentence a future executor reads first and the one 11-09 actually cloned — which no longer says
"tap-DOWN fire" and now cross-references the divergence subsection.

## Verification

- **flutter 608 green** (was 601, exactly +7), `flutter analyze` clean.
- **`browser_screen.dart` zero-line diff** — asserted via `git diff --stat`, the scope fence held.
- No Rust / protocol / extension file touched, so cargo 202 and dart-protocol 13 cannot have regressed.
- **RED proof:** with the wiring reverted to pre-fix, **exactly 4 of the 7 new tests failed** — both
  long-press-empty-folder and both long-press-link, at both layers — matching the plan's prediction.
  The other 3 pass either way by design and pin semantics, not the defect. Source restored
  byte-identical afterwards (`git diff` empty against `a5cd678`).
- **On-device UAT-8 re-run: B1–B6 all PASS**, with B2's folder delete and B3's bookmark delete
  independently confirmed against the profile's `Bookmarks` file (0 `UAT8` remnants anywhere).

## Decisions and discoveries worth carrying

1. **The plan-checker caught a blocker the planner had missed, and it mattered.** The original UAT
   check B1 asked the owner to confirm that holding a non-empty folder does NOT drill in. Post-fix
   that is impossible: a non-deletable row has `onLongPress: null`, so `InkResponse` registers no
   `LongPressGestureRecognizer` at all, leaving the tap recognizer unopposed with no upper time
   bound — it fires on release however long the hold. B1 would have failed a correct build at a
   blocking gate. Rewritten, and the rule is now recorded in `11-UI-SPEC.md` with an explicit
   prohibition on "fixing" it via a dummy `onLongPress`, an `onTapCancel`, or a hold timer.

2. **Why the old suite was green while the device was broken — the interesting part.** The
   pre-existing tests DID use `tester.longPress`, which pumps `kLongPressTimeout + kPressTimeout`
   = 600 ms and genuinely crosses the deadline. Two things hid the defect: they never asserted that
   `onEnterFolder`/`onOpen` stayed unfired, **and** at the section layer the state is a fixed
   parameter, so a recorded `onEnterFolder` swaps nothing and the pressed row survives regardless of
   wiring. Only the real `BookmarksNotifier` replaces the list. Hence the two-layer strategy, and the
   new `_bmDeletable` fixture — `_bmTree` had no empty unlocked folder, so D-14's case had no
   representative at all.

3. **Two contradictions inside the plan, resolved rather than worked around.** Task 1 required a
   comment explaining the absent `onTapCancel` while also asserting `grep -c "onTapCancel"` returns
   0 — kept the reasoning, dropped the literal token. Task 3's prose initially re-introduced the very
   strings its own greps ban. Both criteria now pass verbatim.

4. **Fixture verification caught a duplicate before it corrupted the run.** The UAT setup snippet ran
   twice, producing two identically-titled `UAT8 test folder` rows. The phone would have shown two
   indistinguishable rows and B2's "the folder disappears" check would have been unreadable. Caught
   by checking the profile before B1 — the same discipline that resolved the UAT-6 ambiguity in the
   original run.

5. **Haptic timing moved and was judged acceptable.** `hapticTick()` lives in the screen's callbacks,
   so on bookmark rows the tick now lands on release rather than press. B4 asked the owner to judge
   it against a tab row tapped back to back; it did not read as laggy, so the remedy the plan
   pre-authorised (moving `hapticTick()` into `_flash()`) is NOT needed.

## Follow-ups logged, not fixed

- **Deferred item 4 (new):** the 100 ms press flash is imperceptible on link rows. Verified NOT
  caused by this plan — the flash fires from `onTapDown` before and after, and on a quick tap both
  callbacks land in the same frame either way. Pre-existing; surfaced only because B4 asked the owner
  to look closely at press feedback for the first time. The folder flash, by contrast, became newly
  visible — an improvement, since the drill-in no longer destroys the row mid-flash.
- Deferred items 2 and 3 remain out of scope by owner decision and were not touched.
