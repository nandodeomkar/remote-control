---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 10
subsystem: app
tags: [dart, flutter, riverpod, layout, segmented-control, persistence, lazy-prime, back-navigation]

# Dependency graph
requires:
  - phase: 11-09
    provides: BookmarksSection — the finished region this plan mounts behind the segment
  - phase: 11-08
    provides: bookmarksStateProvider (primeList / enterFolder / goBack / open / remove, depth)
provides:
  - browser_segment.dart — BrowserSegment, kBrowserSegmentPrefsKey, BrowserSegmentStore, browserSegmentStoreProvider, BrowserSegmentNotifier, browserSegmentProvider
  - BrowserSegmentBar + kSegmentTabsLabel / kSegmentBookmarksLabel — the hand-rolled, never-gated Tabs | Bookmarks selector
  - The restructured Browser screen — fixed header, ONE swapped scroll region, pinned macro-grid footer, the D-03 lazy prime and the PopScope folder back
affects: [11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pixel-pinning by layout, not by measurement: moving a widget OUT of the swapped scroll region makes 'same rect in both states' true by construction instead of by assertion — the test then only witnesses it"
    - "Display-driven lazy prime: the guard flips in build off the segment ABOUT TO RENDER, so a value restored from prefs primes on exactly the same path as a tap, with no second code path to keep in sync"
    - "A screen-owned PopScope reading a store's navigation depth: the region widget supplies the on-screen control, the screen supplies the system-back route into the same callback"

key-files:
  created:
    - app/remote_control/lib/browser/browser_segment.dart
  modified:
    - app/remote_control/lib/browser/browser_screen.dart
    - app/remote_control/test/browser/browser_screen_test.dart

key-decisions:
  - "_maybePrimeBookmarks is called from build (not from onSelect) because D-03 says the prime follows DISPLAY: a segment restored from prefs is displayed without any tap, and an onSelect-only prime would silently never fire for that user"
  - "bookmarksStateProvider is watched on BOTH segments — the PopScope's canPop needs the folder depth even while the Tabs list is showing, and the view is value-equal so the extra watch costs no rebuilds"
  - "The system-back path routes through the same _onBookmarksBack as the folder bar's button, haptic included: one back is one back regardless of which surface issued it"
  - "The macro grid's pinned footer carries a TOP-only 1px hairline; it is the boundary signal that content scrolls above it, and it is the only chrome added by the restructure"

patterns-established:
  - "Store-provider override belongs in the shared test harness, not in individual tests, the moment a screen watches that store on every mount (the keyboard_screen_test seam applied to the whole browser file)"

requirements-completed: []

# Metrics
duration: 12min
completed: 2026-07-29
---

# Phase 11 Plan 10: Segmented Browser screen, pinned macro grid, lazy prime Summary

**The macro grid can no longer move: it lives outside the swapped scroll region entirely, so `tester.getRect()` equality across a segment switch and a 21-row folder drill-in is a property of the layout rather than a lucky measurement — and the bookmark tree is asked for exactly once per mount, on the frame it is first displayed, whether the user tapped Bookmarks or the app restored it from prefs.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-07-29T18:28:31Z
- **Completed:** 2026-07-29T18:40:37Z
- **Tasks:** 3
- **Files created/modified:** 3

## Accomplishments

- **`browser.segment` is its own prefs key, its own store, its own notifier.** A `KeyboardPadStore`-shaped clone over the `PrefsKv` seam: unset, unknown, corrupt AND throwing reads all degrade to `BrowserSegment.tabs`, which is today's shipped behaviour — so the worst a hostile or broken preference can do is show the tab list (T-11-14). `grep -c kKeyboardPadPrefsKey` → 0 and `grep -c "flutter_secure_storage\|SecureKv"` → 0: the keyboard's key is never touched and a non-secret preference never reaches the keystore.
- **The screen is now header / swap / footer.** `SafeArea > Column` = banner, `Padding(16, 32, 16, 0)` + `BrowserSegmentBar`, `Expanded > SingleChildScrollView(16, 8, 16, 8)` holding **only** `_TabsSection` or `BookmarksSection`, then a `kBg` `Container` with a 1px `kHairline` **top** border and 16px padding wrapping the untouched `BrowserMacroGrid`. `kBrowserActions` is byte-identical (7 hits, the vocabulary test still green) and `_TabsSection` / `_TabRun` / `_GroupBlock` / `_GroupHeader` / `_TabRow` were not edited at all — the grid only *moved in the tree*.
- **D-02 is proven twice per measurement.** The test captures a key cap's rect and the whole `BrowserMacroGrid`'s rect on Tabs, then re-asserts both after switching to Bookmarks and again after drilling into a folder holding 21 rows. Under the previous single `SingleChildScrollView` that fixture would have pushed the grid hundreds of pixels down the page; under the new tree the two rects are `==`.
- **`_SectionHeader` is gone entirely** — class and call site (`grep -c "_SectionHeader"` → 0). The segment control *is* the section header now, which is why removing it was part of the design rather than cleanup.
- **`BrowserSegmentBar` has no `enabled` parameter and no gated variant,** carrying the `KeyboardTabBar` rule verbatim in spirit: the segment is navigation, not a send. The unauthed test switches segments freely in a frame where a macro button, a tab row and a bookmark row all record nothing. Zero Material segment widgets — `grep -c "SegmentedButton\|ToggleButtons\|TabBar("` → 0 — and zero transition primitives (`AnimatedSwitcher|PageView|FadeTransition|SlideTransition` → 0), so the swap reads at 0 ms as the UI-SPEC's motion budget requires.
- **D-03 holds on both paths.** Screen open records exactly one `TabsListMsg` and **zero** `BmListMsg`; the first Bookmarks display records exactly one `BmListMsg`; a Tabs→Bookmarks round trip records no more. The same single assertion passes when the segment arrives from `load()` instead of a tap, because the guard lives in `build` keyed on the segment about to render.
- **Android back walks the folder stack.** `PopScope(canPop: !inFolder)` intercepts only while the Bookmarks segment shows a subfolder; two `handlePopRoute()` calls climb `Work` → `Bookmarks bar` → roots, after which `canPop` is true again — and it is true on the Tabs segment at any time.
- Suite went **585 → 594 tests**, +9 (all in `browser_screen_test.dart`, which went 22 → 31), `flutter analyze` clean, theme-token and icon guards green, every pre-existing test body unmodified (`git diff` on the test file is **369 insertions, 0 deletions**).

## Task Commits

1. **Task 1: BrowserSegment enum, prefs-backed store and notifier** — `4fe3355` (feat)
2. **Task 2: Layout restructure, BrowserSegmentBar, BookmarksSection wiring, lazy prime** — `4829524` (feat)
3. **Task 3: Screen-level tests — same rect, prime once, position preserved** — `2748c90` (test)

## Files Created/Modified

- `app/remote_control/lib/browser/browser_segment.dart` **(new)** — `enum BrowserSegment`, `kBrowserSegmentPrefsKey`, `BrowserSegmentStore`, `browserSegmentStoreProvider`, `BrowserSegmentNotifier`, `browserSegmentProvider`
- `app/remote_control/lib/browser/browser_screen.dart` — `kSegmentTabsLabel` / `kSegmentBookmarksLabel`, `class BrowserSegmentBar` + its private `_SegmentButton`, the `_bmPrimed` field and `_maybePrimeBookmarks`, the five bookmark/segment callbacks, the restructured `build` body under a `PopScope`, and the deleted `_SectionHeader`
- `app/remote_control/test/browser/browser_screen_test.dart` — `_FakeSegmentStore`, `_bmTree`, `_popScope`, `_selectSegment`, the `bookmarksSnapshot` fake getter, the `browserSegmentStoreProvider` override in `_pumpScreen`, and the 9-test `segmented browser screen (11-10)` group

## Decisions Made

- **The prime fires from `build`, not from `onSelect`.** D-03's wording is "the first time the Bookmarks segment is *displayed*", and a segment restored from prefs is displayed with no tap at all. Priming from `onSelect` would have needed a second, separate hook for the restored case — two code paths for one rule. Reading the segment about to render and flipping `_bmPrimed` before the frame collapses both into one line, and the post-frame callback keeps the send out of the build phase.
- **`bookmarksStateProvider` is watched even on the Tabs segment.** `PopScope.canPop` must be correct in the frame the back gesture arrives, and the depth lives in the bookmarks view. The state is value-equal, so watching it from the Tabs segment produces no extra rebuilds — the alternative (reading depth imperatively inside `onPopInvokedWithResult`) would leave `canPop` itself stale, which is the half that actually decides whether Android pops the route.
- **System back and the folder bar's button share `_onBookmarksBack`, haptic included.** Splitting them would have meant a silent back from one surface and a ticking back from the other for the same navigation step.
- **The pinned footer's hairline is TOP-only.** A full border would draw a box around the grid and read as a card; the single top edge says "content scrolls above this", which is the only new information the restructure introduced.
- **The D-02 fixture uses three real Chrome roots with a 21-child `Bookmarks bar`,** not an artificially flat pile of root-level links. The height difference that matters is the one a real collection produces after one drill-in, and the fixture doubles as the D-04 / back-stack tree.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `_pumpScreen` had to override `browserSegmentStoreProvider`**

- **Found during:** Task 2 (its `flutter test test/browser/` gate)
- **Issue:** The restructured screen watches `browserSegmentProvider`, whose store provider constructs `SharedPrefsKv()` eagerly. In a widget test that throws `Bad state: The SharedPreferencesAsyncPlatform instance must be set`, so **all 17 screen-level tests in the file failed to mount** — including every pre-existing one.
- **Fix:** Extended the shared `_pumpScreen` harness with a `browserSegmentStoreProvider` override backed by a `_FakeSegmentStore` (which extends the real store over a fake `PrefsKv`, so `SharedPrefsKv` is never constructed). This is the shipped house seam — `keyboard_screen_test.dart` overrides `keyboardPadStoreProvider` and `keyboard_panel_test.dart` overrides `keyRowGroupStoreProvider` exactly the same way. No production code was weakened to accommodate a test.
- **Files modified:** `app/remote_control/test/browser/browser_screen_test.dart`
- **Commit:** `4829524` (landed with task 2 rather than task 3, because task 2's own verification gate could not pass without it)
- **Scope note:** no existing test *body* was altered — the change is confined to the shared harness and the fake service, which the plan's own acceptance criterion explicitly permits.

### Clarifications (no behavioural change)

- **The file held 22 pre-existing tests, not the plan's stated 24.** All 22 are green and untouched; the file is now 31. The "+7 or more" floor was met with +9.
- **`simulateSystemBack()` does not exist in this Flutter version.** The back test uses `t.binding.handlePopRoute()` — the idiom `bubble_scaffold_test.dart` already uses for exactly this — plus direct `PopScope.canPop` assertions for the depth-0 case, which is stronger than popping the root route of a `MaterialApp(home:)` harness would have been.
- **`grep -n "getRect"` returns 4 lines, all inside the D-02 test** (a key cap and the whole grid, each measured before and after the switch). An earlier draft factored the measurement into a top-level helper, which satisfied the intent but only produced one line; inlining it also produced the stronger whole-grid assertion.

## Issues Encountered

Two, both resolved inside their own task: the prefs-platform mount failure above, and a compile failure from the non-existent `simulateSystemBack` helper. Neither touched production behaviour.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-09 (EoP, gated commands) | mitigate | `BookmarksSection` and `BrowserMacroGrid` both receive `enabled: authed` from the unchanged `status.chip == ChipStatus.connected` derivation. The segment bar has no `enabled` parameter at all because it issues no command — proven by the unauthed test, where switching works while a macro button, a tab row and a bookmark row all record nothing |
| T-11-14 (DoS, corrupt `browser.segment`) | mitigate | `BrowserSegmentStore.load` degrades unset / unknown / corrupt / throwing reads to `BrowserSegment.tabs` inside a `try` that catches `Object` — a bad preference can only ever select today's default screen |
| T-11-12 (info disclosure, lazy prime) | mitigate | Zero `BmListMsg` recorded on screen open is an explicit assertion; the prime is reachable only from `_maybePrimeBookmarks`, which returns immediately unless the Bookmarks segment is being rendered |
| T-11-04 (tampering, delete path) | mitigate | `_onDeleteBookmark` is passed only as `BookmarksSection.onDelete`, which the section calls exclusively after `confirmDestructive` resolves true. `grep` shows one `remove(` call site on the screen and no other entry point |
| T-11-13 (tampering, PC-supplied titles) | mitigate | The screen passes `bookmarks` through to the section untouched; it never reads, parses or interpolates a title. Every callback carries an id |
| T-11-SC (supply chain) | mitigate | Zero new pub packages; `pubspec.yaml` untouched and not in `files_modified` |

No new security-relevant surface beyond the register — no threat flags.

## Known Stubs

None. Every symbol this plan declares is implemented and screen-exercised. The one deliberate gap is the tab-row **star slot** (D-09 / D-11 / D-12), which 11-11 owns: `TabsNotifier.star` / `unstar` and the unstar copy consts still have no caller in `lib/`, exactly as 11-08 and 11-09 planned.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **11-11 (the star slot) inherits a stable `_TabRow`.** This plan did not touch it, so the star insert lands against the shipped chrome; the row's right padding drop (12px → 4px when a slot renders) is still entirely 11-11's edit.
- **The install-hint coherence requirement is now structurally satisfied:** both segments render the same `InstallHintCard` off `connected` from their own store, and both stores read the same `ConnectionService` snapshots, so they cannot disagree in a frame.
- **Any new screen-level browser test must pump through `_pumpScreen`** — the `browserSegmentStoreProvider` override lives there, and a hand-rolled `ProviderScope` will throw on the prefs platform.
- **`_FakeSegmentStore(initial:)` is the seam for "the user last left the screen on Bookmarks"** if 11-12 needs to exercise a restored segment.
- **On-device carry-forward:** the pinned footer means the tab/bookmark list now scrolls under a fixed grid. Worth one look during the phase's UAT that the grid does not crowd the list on a short device — the layout is correct by construction, but the *proportion* is a judgement only the owner can make.

## Self-Check: PASSED

All three claimed files exist on disk and carry the claimed symbols: `enum BrowserSegment` ×1, `kBrowserSegmentPrefsKey = 'browser.segment'` ×1, `browserSegmentStoreProvider` ×1 in the store file, `kKeyboardPadPrefsKey` ×0, `flutter_secure_storage|SecureKv` ×0; in `browser_screen.dart` `class BrowserSegmentBar` ×1, `SegmentedButton|ToggleButtons|TabBar(` ×0, `_SectionHeader` ×0, `_bmPrimed` ×4, `primeList()` ×2, `PopScope` ×1, `AnimatedSwitcher|PageView|FadeTransition|SlideTransition` ×0, `EdgeInsets.fromLTRB(16, 32, 16, 0)` ×1, `kBrowserActions` ×7; in the test `getRect` ×4, `BmListMsg` ×4, `BrowserSegment.bookmarks` ×2, and `git diff --stat` shows 369 insertions / 0 deletions. All three task commits (`4fe3355`, `4829524`, `2748c90`) are present in git history on `master`.

Verification re-run at plan close: `flutter analyze` **No issues found!**; `flutter test` **594 passed / 0 failed**; `flutter test test/browser/browser_screen_test.dart` **31 passed**; `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` **2 passed**.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
