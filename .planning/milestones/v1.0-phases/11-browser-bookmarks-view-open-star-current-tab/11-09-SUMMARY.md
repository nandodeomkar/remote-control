---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 09
subsystem: app
tags: [dart, flutter, widget, bookmarks, ui-contract, destructive-confirm, accessibility]

# Dependency graph
requires:
  - phase: 11-08
    provides: BookmarksViewState (currentChildren / depth / currentFolderTitle / currentFolderTruncated / hasDeletableChild / isDeletable) — the state this widget renders
  - phase: 11-07
    provides: BmNode — the node shape each row reads
provides:
  - install_hint_card.dart — the public InstallHintCard both Browser segments render, with kInstallHintTitle / kInstallHintBody
  - bookmark_confirm.dart — confirmDestructive plus the ten named copy consts for unstar, bookmark delete and folder delete
  - bookmarks_section.dart — BookmarksSection (folder bar, folder/link rows, body-state ladder, truncation + empty + hint copy, the long-press delete gate)
affects: [11-10, 11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Affordance gating as the security control: a non-deletable row gets onLongPress: null with NO visual difference, so the destructive path is not merely refused but unreachable and undiscoverable"
    - "Confirm helper returns `result == true`, so a barrier dismissal collapses into the cancel branch and no caller ever distinguishes dismissed from declined"
    - "A shared fallback widget extracted to its own file (not re-exported from a screen) is what makes two segments structurally unable to word the same failure differently"

key-files:
  created:
    - app/remote_control/lib/browser/install_hint_card.dart
    - app/remote_control/lib/browser/bookmark_confirm.dart
    - app/remote_control/lib/browser/bookmarks_section.dart
    - app/remote_control/test/browser/bookmarks_section_test.dart
  modified:
    - app/remote_control/lib/browser/browser_screen.dart

key-decisions:
  - "The trailing lines (folder truncation + long-press hint) render only when connected — a 'Long-press a bookmark to delete it.' line under an install-hint card would advertise an affordance no row on screen has"
  - "A folder with a null count renders '· 0' rather than '· null'; BookmarksViewState.isDeletable already treats null count as non-deletable, so the row can never invite a delete the count contradicts"
  - "The leading glyph is resolved into a local before the Row so the two Symbols constants sit on their own lines — the phase's icon-vocabulary grep gate counts matching LINES, not occurrences"
  - "ensureSemantics() is disposed inside the test body, not via addTearDown: the framework verifies outstanding semantics handles BEFORE tearDowns run"

patterns-established:
  - "Component-before-wiring: build the region as a parameter-driven widget with recorded callbacks so the gates are provable without a screen, a service fake or a ProviderContainer — the next plan receives a finished contract instead of exploring for one"

requirements-completed: []

# Metrics
duration: 8min
completed: 2026-07-29
---

# Phase 11 Plan 09: Bookmarks region widget, shared install hint, confirm gate Summary

**The subtree wipe is now structurally unreachable from the UI: a non-empty folder, a locked node and every root are handed `onLongPress: null` with no visual tell at all, every delete that IS offered resolves through one confirm whose barrier dismissal reads as cancel, and the extension-missing state is one widget with one copy that both Browser segments render.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-29T18:11:34Z
- **Completed:** 2026-07-29T18:19:35Z
- **Tasks:** 3
- **Files created/modified:** 5

## Accomplishments

- **`InstallHintCard` is now one widget, not two.** `_InstallHintCard` moved out of `browser_screen.dart` verbatim — same fill, border, radius 16, padding 16, 24px muted glyph, 12px gap, the grandfathered 14/600 title, 4px gap, 12/400 body — with its copy lifted to `kInstallHintTitle` / `kInstallHintBody`. `browser_screen.dart` keeps exactly one reference and zero private copies (`grep -c "_InstallHintCard"` → 0). The two shipped install-hint assertions in `browser_screen_test.dart` never noticed.
- **One `confirmDestructive`, ten copy consts, one `kError` site.** The dialog is a clone of the shipped revoke gate (kSurface, radius 16, 16/600 title, 14/400 body, muted Cancel, `kError`/`kBg` FilledButton at `minimumSize (0, 48)`), and `kError` appears in the whole file exactly once — as that button's fill. The doc comment records WHY this shape and not the Power screen's slide-to-confirm: escalating a bookmark deletion to the gesture reserved for irreversible machine state would train the owner to slide through it where it actually matters.
- **The D-14 gate is an affordance gate, not a refusal.** `onLongPress` is `null` unless `BookmarksViewState.isDeletable` (11-08's shared predicate — deliberately not re-derived) says the node is a link or a `count == 0` folder, and unlocked in both cases. There is no visual difference, no disabled state, nothing to discover. Two `findsNothing` tests pin it: a non-empty folder and a locked *empty* folder (which isolates `locked` from `count`) both open no dialog.
- **Truncation honesty is a body-ladder branch, not a copy tweak.** A folder that is empty AND truncated falls through the `kBmEmptyFolder` branch to an empty row list, so what the user reads is `Some bookmarks here aren't shown.` — proven by a test that asserts the truncation line present and the empty line absent in the same frame.
- **The back control is live while gated.** `enabled: false` nulls tap-down and long-press on every row, but the folder bar's back button is untouched — popping a folder is local navigation, not a send, and gating it would strand an offline user inside a subfolder. One test taps a link (records nothing), long-presses it (opens nothing) and then taps back (fires once) in a single gated mount.
- **The icon-only back button carries `kBmBackSemantic`,** asserted via `find.bySemanticsLabel` under an explicit `ensureSemantics()` handle — the one control in this region a screen reader could not otherwise name.
- Suite went **567 → 585 tests**, +18 (all in the new `bookmarks_section_test.dart`), `flutter analyze` clean, theme-token and icon guards green, all 33 pre-existing browser tests untouched and passing.

## Task Commits

1. **Task 1: Extract the shared install-hint card and create the confirm-dialog helper** — `80c83a9` (feat)
2. **Task 2: BookmarksSection — folder bar, rows, body-state ladder, delete gate** — `2979f6c` (feat)
3. **Task 3: Isolated widget tests for the bookmarks region** — `71eb753` (test)

## Files Created/Modified

- `app/remote_control/lib/browser/install_hint_card.dart` **(new)** — `kInstallHintTitle`, `kInstallHintBody`, `class InstallHintCard`
- `app/remote_control/lib/browser/bookmark_confirm.dart` **(new)** — the ten `kBm*` copy consts and `Future<bool> confirmDestructive(...)`
- `app/remote_control/lib/browser/bookmarks_section.dart` **(new)** — `kBmNoBookmarks`, `kBmEmptyFolder`, `kBmTruncatedSnapshot`, `kBmTruncatedFolder`, `kBmDeleteHint`, `kBmBackSemantic`, `class BookmarksSection`, the private `_MutedLine` one-liner and the private `_BmRow` stateful row
- `app/remote_control/lib/browser/browser_screen.dart` — the private card deleted (46 lines), the shared file imported, the single call site renamed; nothing else touched
- `app/remote_control/test/browser/bookmarks_section_test.dart` **(new)** — 18 tests over a hand-built seven-node fixture tree

## Decisions Made

- **Trailing lines are gated on `connected`.** The truncation line and the long-press hint render only when the extension is up. `hasDeletableChild` would already be false with an empty node list, but the guard is explicit because the failure it prevents — a hint advertising a gesture no visible row offers, sitting under an install card — is the incoherent-screen mode the UI-SPEC calls the phase's most visible failure.
- **`'· ${count ?? 0}'` instead of the plan's literal `'· ${node.count}'`.** A null count would render the string `· null` on a real row. The extension always emits `count` on folders, so this is defensive only, and it stays consistent with `isDeletable`, which treats a null count as non-deletable — the row can never show a count that contradicts its affordance.
- **The leading glyph is a local, not an inline ternary.** `Symbols.folder_rounded` and `Symbols.bookmark_rounded` sit on separate lines because the phase's icon-vocabulary gate counts matching *lines*; an inline ternary would collapse two vocabulary entries into one grep hit and let a future deletion pass unnoticed.
- **`_BmRow` carries a `ValueKey(node.id)`.** Rows are rebuilt wholesale on every drill-in and every pushed snapshot; without an identity key Flutter would recycle a row's `State` — and therefore its in-flight 100ms press-flash — onto a different node after a folder swap.
- **`ensureSemantics()` disposed in the test body.** `WidgetTester._verifySemanticsHandlesWereDisposed` runs before registered tearDowns, so `addTearDown(handle.dispose)` fails the test it is meant to clean up (caught on first run, fixed in place).

## Deviations from Plan

**None** — all three tasks executed as written. Two clarifications, neither a behavioural change:

- **Test count came in above the floor:** the plan asked for "12 or more"; 18 shipped (the nine listed coverage areas split naturally into 18 named cases across 7 groups).
- **The `_settleFlash` helper exists because tap-down fires a real `Future.delayed`.** Every tap test pumps 150ms afterwards so the press-flash relax cannot outlive the widget tree — the same discipline `media_screen_test` applies to the header chip's ticker.

## Issues Encountered

One test-harness failure on first run: `A SemanticsHandle was active at the end of the test.` The handle registered via `addTearDown` is verified *before* tearDowns execute. Fixed by disposing inside the test body with a comment recording why. No production code was involved.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-13 (tampering, PC-supplied titles) | mitigate | Titles render as plain `Text` with `maxLines: 1` + `TextOverflow.ellipsis`, never parsed, never interpolated into a command, never used as identity. `onOpen` / `onEnterFolder` / `onDelete` are all passed `node.id` and nothing else |
| T-11-04 (tampering, delete affordance) | mitigate | `onLongPress: null` unless `BookmarksViewState.isDeletable`; the non-empty-folder and locked-node `findsNothing` tests are the proof. Roots arrive `locked` so they need no special case |
| T-11-06 (tampering, accidental deletion) | mitigate | `grep -c "Dismissible"` → 0 (no swipe on a bookmark row); every delete resolves through `confirmDestructive`, and the Cancel path is unit-proven to fire `onDelete` zero times. Barrier dismissal returns `null` → `result == true` is false → cancel |
| T-11-09 (EoP, gated state) | mitigate | `enabled == false` nulls tap-down and long-press; the gated test records zero opens and zero dialogs while the back button still fires. `grep -c "kError"` in `bookmarks_section.dart` → 0 (gated is muted, never red) |
| T-11-01 (info disclosure, truncation honesty) | mitigate | The empty-AND-truncated test asserts `kBmTruncatedFolder` present and `kBmEmptyFolder` absent in the same frame |
| T-11-SC (supply chain) | mitigate | Zero new pub packages; `pubspec.yaml` untouched and not in `files_modified` |

No new security-relevant surface beyond the register — no threat flags.

## Known Stubs

None. Every symbol this plan declares is implemented and widget-exercised. `BookmarksSection` and `confirmDestructive` have no caller in `lib/` yet **by design** — 11-10 mounts the section behind the segment control, and 11-11 is the unstar copy set's only consumer. The plan is explicitly the component layer; wiring is the next plan's scope.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **11-10 (screen wiring) receives a finished contract:** `BookmarksSection(bookmarks:, enabled:, onOpen:, onEnterFolder:, onBack:, onDelete:)`. Every callback reports intent only — the screen must add `hapticTick()` at each site and route `onOpen`/`onDelete` to `BookmarksNotifier.open` / `.remove`, and `onEnterFolder`/`onBack` to `.enterFolder` / `.goBack`.
- **The `PopScope` half of the back story is NOT in this widget.** `canPop: depth == 0` plus routing Android back through `goBack()` belongs to the screen; the folder bar only supplies the on-screen control.
- **11-11 imports `bookmark_confirm.dart` directly** for `kBmUnstarTitle` / `kBmUnstarBody` / `kBmUnstarConfirm` — the unstar copy already ships here, so the star slot must not declare its own strings.
- **Both segments must flip to `InstallHintCard` in the same frame.** They now render the identical widget, so the only remaining way to break that is for the screen to read `connected` from two different snapshots.
- **Carry-forward from 11-08 still open:** `primeList()` must be called from the segment's `onSelect` guarded by a `bool _bmPrimed` (D-03), never from `initState`.

## Self-Check: PASSED

All five claimed files exist on disk and carry the claimed symbols: `class InstallHintCard` ×1, `_InstallHintCard` in `browser_screen.dart` ×0, `InstallHintCard` in `browser_screen.dart` ×1, `Future<bool> confirmDestructive` ×1, `^const String kBm` in `bookmark_confirm.dart` ×10, `kError` in `bookmark_confirm.dart` ×1, `class BookmarksSection extends StatelessWidget` ×1, `^const String kBm` in `bookmarks_section.dart` ×6, `Icons.` ×0, the four `Symbols.*` vocabulary lines ×4, `Dismissible` ×0, `kError` ×0, `SnackBar|showSnackBar` ×0, and the spacing grep yields only 4 / 8 / 16 / 48 / 56 — all on-grid, no new off-grid value. `bySemanticsLabel` ×1 and `kBmDeleteFolderTitle|kBmDeleteBookmarkTitle` ×7 in the test. All three task commits (`80c83a9`, `2979f6c`, `71eb753`) are present in git history on `master`.

Verification re-run at plan close: `flutter analyze` **No issues found!**; `flutter test` **585 passed / 0 failed**; `flutter test test/browser/bookmarks_section_test.dart` **18 passed**; `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` **2 passed**.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
