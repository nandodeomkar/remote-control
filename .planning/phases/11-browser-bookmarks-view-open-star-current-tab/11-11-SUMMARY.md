---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 11
subsystem: ui
tags: [flutter, riverpod, material-symbols, semantics, gesture-arena, bookmarks]

# Dependency graph
requires:
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-08)
    provides: "TabsViewState.bookmarkedFor tri-state resolver, TabsNotifier.star/unstar with the D-12 optimistic overlay"
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-09)
    provides: "confirmDestructive + kBmUnstarTitle/Body/Confirm and kBmConfirmCancel"
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-10)
    provides: "the segmented Browser screen whose _TabsSection the star threads through"
provides:
  - "kStarSemantic / kUnstarSemantic — the state-announcing star labels"
  - "the 48x48 trailing star slot on every tab row whose bookmark state is known"
  - "_TabsSection.bookmarkedFor + onStar threading to _TabRow"
  - "_BrowserScreenState._onStarTab — instant add, confirm-gated remove"
  - "7 star widget tests: tri-state, arena isolation, gating, confirm gate, optimistic flip, label pinning, null-row regression"
affects: [11-12, browser, bookmarks, accessibility]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Per-Icon FILL-axis override as a state signal (beats the app-wide FILL 0 pin from buildAppTheme)"
    - "Semantics(container: true, enabled: ...) on an icon-only button so a DISABLED control still has an a11y node"
    - "Nested-recognizer isolation pinned by observation (zero TabsActivateMsg) rather than by reasoning about tap deadlines"

key-files:
  created: []
  modified:
    - app/remote_control/lib/browser/browser_screen.dart
    - app/remote_control/test/browser/browser_screen_test.dart

key-decisions:
  - "D-11 UNKNOWN renders NO slot and NO Semantics node — the row and its a11y tree stay byte-identical to the pre-phase row, because an empty star on an unreadable state would be a misreport"
  - "The gated star needs container: true + enabled: false on its Semantics, otherwise the null onTap leaves the label with no node at all and a screen reader hears nothing instead of a disabled button (T-11-09)"
  - "Task 1 shipped the star with a no-op handler for one commit on purpose, so no unconfirmed destructive unstar path ever existed in history"

patterns-established:
  - "Row-scoped test finders (_rowOf / _star / _rowSemantics) address ONE tab row through its nearest Material ancestor, so a per-row assertion can never pick up a sibling row"
  - "Gated-geometry proof by comparing rects captured from a CONNECTED pump of the same fixture on the same surface, rather than asserting absolute pixel values"

requirements-completed: []

# Metrics
duration: 35min
completed: 2026-07-30
---

# Phase 11 Plan 11: Tab-row star slot Summary

**A 48x48 trailing star on every tab row whose bookmark state is known — `Symbols.star_rounded` differentiated by the FILL axis, instant on add, `confirmDestructive`-gated on remove, and completely absent when the state is UNKNOWN.**

## Performance

- **Duration:** 35 min
- **Started:** 2026-07-30T01:52:00Z
- **Completed:** 2026-07-30T02:27:00Z
- **Tasks:** 3
- **Files modified:** 2

## Accomplishments

- `kStarSemantic` / `kUnstarSemantic`: the star is icon-only and encodes its state in the FILL axis alone, so the label — which flips with the state — is the only channel carrying bookmarked/not-bookmarked to a non-visual user.
- Tri-state rendering straight off `TabsViewState.bookmarkedFor`: `true` → `fill: 1` + `kAccent`, `false` → `fill: 0` + `kMuted`, `null` → **no slot at all**, no `SizedBox`, no `Semantics` node. The row's right padding drops 12 → 4 only when a slot renders, so a null-state row is byte-identical to the pre-phase row.
- `_onStarTab`: adding sends `bm.star` + haptic on the tap instant (the glyph already flipped via the D-12 overlay); removing opens the confirm FIRST and changes nothing until it resolves true, with the flip and the haptic landing on the **Remove** press. Cancel and barrier dismissal send nothing. No toast either way — the `bm.*` family carries no `err` reply.
- The gesture arena question (RESEARCH Pitfall 8 / assumption A6) is now settled by **observation**: a star tap records exactly one `BmStarMsg` and **zero** `TabsActivateMsg`. The row's tap-down activate, 100 ms flash, long-press close and `Dismissible` swipe are all untouched.
- Gated is muted, inert and geometrically identical — proven by comparing the star's and the row's rects against a connected pump of the same fixture.
- 7 new widget tests (file 31 → 38), every pre-existing test byte-untouched and green.

## Task Commits

1. **Task 1: Trailing star slot on `_TabRow` with tri-state rendering and semantics** — `4cc2120` (feat)
2. **Task 2: Star instant, unstar confirm-gated** — `411ac92` (feat)
3. **Deviation (Rule 2): keep the gated star's semantics node** — `b513149` (fix)
4. **Task 3: Star widget tests — tri-state, arena isolation, gating, confirm, flip** — `44b0eb9` (test)

## Files Created/Modified

- `app/remote_control/lib/browser/browser_screen.dart` — `kStarSemantic` / `kUnstarSemantic`; `_TabsSection.bookmarkedFor` + `onStar` threaded to `_TabRow` alongside `enabled`/`onActivate`/`onClose`; `_TabRow.bookmarked` (tri-state) + the 48x48 star slot with the FILL-axis glyph, the conditional right padding and the `starColor` resolution; `_onStarTab` on `_BrowserScreenState`; `bookmark_confirm.dart` import.
- `app/remote_control/test/browser/browser_screen_test.dart` — the `_triStateTabs` fixture, the `_rowOf` / `_star` / `_rowSemantics` row-scoped finders, and the 7-test `tab row star (11-11)` group.

## Decisions Made

- **Star colour resolution collapsed to one expression:** `kAccent` only when `bookmarked == true && enabled`, `kMuted` in every other rendered case. The destructive red is now grep-provably absent from `browser_screen.dart` (count 0), which is the cheapest possible enforcement of "never red on a star".
- **The row resolves, the row renders:** `bookmarkedFor(tab)` is called in `_TabsSection._row` and `_TabRow` receives the already-resolved `bool?`, so the row stays a dumb renderer of a tri-state value exactly like it is for `enabled`. `onStar` carries `(tabId, bookmarked)` — the state the row actually **drew** — so the add/remove split can never disagree with the glyph the user tapped.
- **Task 1 shipped a no-op `onStar`** rather than a partially-gated handler, so no commit in history contains an unstar that could fire without the confirm.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] The gated star's semantics node disappeared entirely**

- **Found during:** Task 3 (the gated-inertness test failed on `find.bySemanticsLabel(kUnstarSemantic)` → 0 matches)
- **Issue:** The plan's snippet is `Semantics(button: true, label: …)` with `container` defaulting to false. When `enabled` is false the star's `InkWell` gets `onTap: null` and therefore produces **no semantics node**, and a `container: false` annotation has none of its own — so the label was silently dropped from the semantics tree in exactly the state that most needs explaining. A screen-reader user would hear **nothing** where T-11-09 mandates "reads as disabled rather than absent", and the plan's own must-have ("a screen reader hears which state the star is in") would have been false while gated. Only visible because the test asserted the rendered tree rather than the widget tree.
- **Fix:** added `container: true` (so the node always exists) and `enabled: widget.enabled` (so the state is announced as *disabled* rather than as a button that does nothing) to the star's `Semantics`. Nothing else changed: the label, the geometry and the connected-state assertions are unaffected.
- **Files modified:** `app/remote_control/lib/browser/browser_screen.dart`
- **Verification:** the gated test now asserts BOTH the widget-level label (`_rowSemantics`) and the rendered-tree label (`find.bySemanticsLabel`) under `ensureSemantics()`; `flutter test` 601/601 green, `flutter analyze` clean.
- **Committed in:** `b513149` (own commit, kept separate from the test commit so each is independently green)

---

**Total deviations:** 1 auto-fixed (1 missing critical / accessibility mitigation)
**Impact on plan:** Closes the T-11-09 mitigation the plan intended but its snippet could not deliver. Two extra parameters on one `Semantics` widget — no scope creep, no structural change.

## Issues Encountered

- **Two acceptance greps failed on prose, not code:** `Symbols.star_rounded` counted 2 and `kError` counted 1 because my `_TabRow` doc comment and an inline comment *named* them. Both were reworded ("the rounded star glyph", "the destructive red") so the counts are 1 and 0 as the plan requires — the greps are guards against a second glyph reference and against red ever reaching a star, and prose that trips them makes the guard useless.
- **Known behavioural edge, deliberately not fixed (out of scope):** `t.tap()` sends down+up with no time between, so the row's `TapGestureRecognizer` never exceeds its 100 ms deadline and only the star's nested recognizer fires — which is what the A6 test pins. On a real device, *pressing and holding* the star for >100 ms will also fire the row's `onTapDown` (Flutter calls `handleTapDown` on deadline expiry, not only on winning the arena), so a slow press on the star can additionally activate the tab. Harmless and self-healing (a tab switch, not a destructive act), and fixing it would require restructuring the row's locked press-down activate — which the plan explicitly forbids. Logged to `deferred-items.md`.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The full D-09/D-11/D-12 star surface is complete and pinned; 11-12 (docs + UAT) can write its on-device steps against the shipped behaviour.
- Wave-merge gate green across all three trees: `flutter analyze` clean, `flutter test` 601 passed, `cargo test --workspace` 202 passed, `dart test` (remote_protocol) 13 passed.
- Nothing blocks the phase's remaining plan. The only open item is the >100 ms press-and-hold nuance above, which is deferred, not a blocker.

## Self-Check: PASSED

- `app/remote_control/lib/browser/browser_screen.dart` — FOUND
- `app/remote_control/test/browser/browser_screen_test.dart` — FOUND
- `.planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-11-SUMMARY.md` — FOUND
- Commits `4cc2120`, `411ac92`, `b513149`, `44b0eb9` — all FOUND in git history

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-30*
