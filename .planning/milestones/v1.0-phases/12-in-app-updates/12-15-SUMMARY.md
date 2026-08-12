---
phase: 12-in-app-updates
plan: 15
subsystem: updates
tags: [dart, flutter, riverpod3, ui, widget-tests, accessibility, ui-contract]

# Dependency graph
requires:
  - phase: 12-in-app-updates (12-14)
    provides: UpdatesViewState / UpdateRowState / UpdateRowKind / UpdateFailure / CheckFooterState, updatesStateProvider, updateBadgeProvider, the five effect seams + updateClockProvider
  - phase: 12-in-app-updates (12-07)
    provides: formatAgo / formatSize
  - phase: 12-in-app-updates (12-08)
    provides: ApkInstaller.openInstallPermission
provides:
  - "UpdatesScreen — the three component rows, the check footer and the D-19 explainer sheet"
  - "UpdateRow, CheckFooter, InstallPermissionSheet, UpdateBadgeDot, UpdatesNavRow"
  - "updateRowSubtitle / updateFailureSentence / updateRowActionLabel / checkFooterStatus — the copy contract as four pure functions"
  - "The Updates entry in the Settings About group, and the badge dot in both placements"
affects: [12-17, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "The copy contract as pure functions over the state enum, so every user-visible sentence is assertable without a widget"
    - "A stub Notifier subclass as the widget-test seam: build() overridden whole, so the screen renders with no socket, no feed and no platform channel"
    - "A test-side matrix table whose completeness is itself a test (covered kinds == UpdateRowKind.values)"
    - "Fixed-height subtitle box + reserved trailing slot, so a row cannot resize between states"

key-files:
  created:
    - app/remote_control/lib/update/updates_screen.dart
    - app/remote_control/test/update/updates_screen_test.dart
  modified:
    - app/remote_control/lib/settings/settings_screen.dart
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/test/settings_screen_test.dart

key-decisions:
  - "The row body carries NO recognizer at all — no InkWell, no press flash. The row's only gesture is the trailing TextButton's, so there is no gesture arena in which a mis-tap on the body could start a 70 MB download or a PC install (T-12-51). The press-flash idiom is deliberately absent because it signals 'this fires something'."
  - "All three rows render in EVERY state. A missing or unreachable component is a state OF the row, never an absent row — a screen whose row count changes with connectivity breaks the three-components promise of SC3."
  - "The subtitle is a fixed two-line box and the trailing slot reserves 48px, so `available`, `downloading` and `failed` are byte-identical in height. Nothing below the row moves while a download ticks."
  - "The Extension row's trailing slot is empty in every state, spinner included. The matrix lists `checking` as applying to all three rows with a busy spinner, but the trailing-slot table says Empty is used 'always on the Extension row' — the more specific rule wins, and `neverActs` implements it structurally."
  - "The download percentage lives in the subtitle as live text, never in the trailing slot. The arc is the ambient signal and the number is the precise one; they do not share a place, and the spinner is wrapped in ExcludeSemantics so a screen reader hears the stage once."
  - "Row `Retry` for a PC failure re-applies a widget-local remembered target (`_lastPcTarget`). A `failed` state carries no target, and the memory must NOT survive a process restart — a stale target is exactly what the server's `stale` guard exists to refuse. With no remembered target the Retry re-resolves the feed rather than guessing a version."
  - "The sheet is the phase's ONLY FilledButton. Dismiss by scrim, by back gesture and by `Not now` all resolve identically: the row stays on `available`, nothing downloads, nothing is logged as a failure. The app never polls for the grant and never auto-resumes on return."
  - "The badge is one widget reading one provider, placed twice. In Settings it is an inline row child; in the hub it is a `Positioned` overlay on the existing gear `IconButton`, so the app bar cannot reflow when an update lands. The gear's tooltip carries the state for a screen reader — `IconButton` surfaces tooltip as its semantics label, so it costs no extra node and cannot desync from the dot."
  - "No pumpAndSettle anywhere in the widget suite. ConnectionHeaderChip runs a 500ms Timer.periodic setState, so settling never terminates; every wait is an explicit pump with a duration and every test unmounts to cancel the ticker."

patterns-established:
  - "Stub-notifier widget testing: `overrideWith(() => stub)` on a NotifierProvider whose `build()` is overridden whole — the screen under test is exercised against a value, and the state machine's own suite proves the value is reachable"
  - "A completeness test over the test table itself, so a new enum member fails the suite rather than silently going unrendered"
  - "Copy assembled in tests from the shipped consts and the shipped formatter, never hand-typed, so a copy change cannot pass by being wrong in two places at once"

requirements-completed: [D-06, D-07, D-08, D-11, D-13, D-17, D-18, D-19, D-22, D-23, D-24, D-25, D-26, SC3, SC4]

# Metrics
duration: 3 sessions
completed: 2026-08-04
---

# Phase 12 Plan 15: The Updates Screen Summary

**Every state the 12-14 machine can produce now has a proven rendering: three rows that never change in number or height, a closed vocabulary of seven sentences, one retry, one filled button, and a badge that reaches the semantics tree from a single source of truth.**

## Performance

- **Duration:** 3 sessions (tasks 1-2, then task 3)
- **Tasks:** 3
- **Files modified:** 5 (2 created, 3 modified)
- **Tests added:** 55 (49 screen, 6 Settings)

## Accomplishments

- **The whole matrix renders.** All 15 `UpdateRowKind` values plus the three `available` variants are pumped through the real widget tree and asserted for their exact subtitle sentence and their exact trailing slot. A completeness test compares the covered kinds against `UpdateRowKind.values`, so a state added to the machine fails this suite rather than shipping unseen — that is the executable form of SC3.
- **The three rows are structural.** The row count is asserted at exactly three with the socket down and after a feed failure, and the fixed order (App → PC → Extension) is asserted by vertical position. The App row leads because it is the only update completable with no PC in the room.
- **The row does not resize.** `getRect` on the App row is identical across `available`, `downloading` and `failed` — the fixed two-line subtitle box plus the 48px reserved trailing slot, proven rather than described.
- **Nothing leaks.** No `kError` text, glyph, indicator or surface, and no `SnackBar` or `Dialog`, exists in any matrix state — swept on every one of the 30 matrix cases, not once. The five failure sentences are the only failures representable, so no code, status, path, URL or hash can reach the screen (T-12-06).
- **One retry, in the footer.** A feed failure puts all three rows on `Couldn't check` and produces exactly one widget carrying `Retry`, asserted to be a descendant of `CheckFooter` (D-22).
- **The Extension row has no affordance in any state** — not an enabled one and not a greyed one. Asserted across every extension state by both `TextButton` and `ButtonStyleButton` finding nothing (D-18).
- **The row body cannot start anything.** Tapping the title and the subtitle of an actionable row fires no download, sends no apply, opens no sheet and pushes no route; the body has no `InkWell` and no `GestureDetector` ancestor. The trailing button's own `InkWell` is the row's only recognizer (T-12-51).
- **The D-19 sheet behaves in all three directions.** Missing grant opens it and leaves the row on `available`; `Not now` routes nowhere and retries nothing; the CTA opens system settings exactly once and does not auto-resume. A granted `Update` never opens it at all.
- **The badge is announced, not just drawn.** With semantics enabled, `Update available` is present in the tree when the provider is true and absent when false — the dot carries no text, so without the label the state would be shown and never spoken.

## Task Commits

1. **Task 1: the Updates screen — UpdateRow, CheckFooter and the copy contract** — `f6c4bdc` (feat)
2. **Task 2: the Settings entry and both badge placements** — `eef00dd` (feat)
3. **Task 3: widget tests across the whole state matrix** — `f1f70a6` (test), with `f2bea22` (fix) for the defect it caught

## Files Created/Modified

- `app/remote_control/lib/update/updates_screen.dart` (new, ~967 lines) — the copy consts, the four pure copy functions, `UpdatesScreen`, `UpdateRow`, `CheckFooter`, `InstallPermissionSheet`, `UpdateBadgeDot`, `showInstallPermissionSheet`
- `app/remote_control/test/update/updates_screen_test.dart` (new, ~1080 lines) — 49 tests over a stub notifier
- `app/remote_control/lib/settings/settings_screen.dart` — `UpdatesNavRow` and the Updates entry as the first child of the About group; the shipped `Version` row unmoved
- `app/remote_control/lib/hub/hub_screen.dart` — the `Positioned` badge overlay and the conditional tooltip on the existing settings `IconButton`
- `app/remote_control/test/settings_screen_test.dart` — a `badge` parameter on the host and 6 tests for the entry, the dot and its semantics label

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] The `checking` footer rendered in the theme's disabled grey, not `kMuted`**

- **Found during:** Task 3
- **Issue:** The UI-SPEC footer table gives `checking` a `kMuted` foreground and a null `onPressed`. `TextButton.icon` resolves `foregroundColor` only for the enabled states — with `onPressed: null` it fell back to the Material theme's own disabled colour, so the one state the table describes as muted was the one state that was not.
- **Fix:** `disabledForegroundColor: foreground` in the button's `styleFrom`, with a comment stating why the two must agree.
- **Files modified:** `lib/update/updates_screen.dart`
- **Verification:** `the check footer (D-07) checking is muted and non-pressable` resolves the style against `WidgetState.disabled` and asserts `kMuted`.
- **Committed in:** `f2bea22`

**2. [Rule 1 - Bug] The row-inertness assertion was scoped to the row, not the body**

- **Found during:** Task 3
- **Issue:** A first pass asserted no `InkWell` anywhere in `UpdateRow`, which fails by construction: a Material `TextButton` builds one internally, and that button is the row's *intended* recognizer.
- **Fix:** The assertion is scoped to the body — no `InkWell` or `GestureDetector` may be an ancestor of the title or the subtitle, which is where a mis-tap actually lands. A second test covers the whole row for a state with no action, where the count must be zero.
- **Files modified:** `test/update/updates_screen_test.dart`
- **Verification:** both `the row body carries no recognizer and no press flash` and `a row with no action carries no recognizer at all`.
- **Committed in:** `f1f70a6`

**3. [Rule 1 - Bug] `find.bySemanticsLabel` with a whole-string match found nothing**

- **Found during:** Task 3
- **Issue:** The Settings row is an `InkWell`, so the badge's `Semantics` node is merged into the row's and the announced string carries the row title too. An exact-string `bySemanticsLabel` therefore matched no node even though the label was present.
- **Fix:** Matched with an escaped `RegExp`, which `bySemanticsLabel` evaluates as a substring test. The absence case uses the same pattern, so it is still a real negative.
- **Files modified:** `test/settings_screen_test.dart`
- **Verification:** the label is found with `badge: true` and not found with `badge: false`.
- **Committed in:** `f1f70a6`

**4. [Rule 1 - Bug] `addTearDown(handle.dispose)` fails the test it cleans up after**

- **Found during:** Task 3
- **Issue:** `flutter_test` runs its end-of-test `SemanticsHandle` check *before* tear-downs, so deferring `dispose` to `addTearDown` reports "A SemanticsHandle was active at the end of the test".
- **Fix:** Disposed inline at the end of both semantics test bodies, with the ordering recorded in a comment.
- **Files modified:** `test/settings_screen_test.dart`
- **Verification:** both tests pass.
- **Committed in:** `f1f70a6`

---

**Total deviations:** 4 auto-fixed (1 production bug, 3 test-harness bugs). No architectural change, no new dependency, no scope creep. Deviation 1 is the one that mattered: a contract state that rendered wrong and would have shipped, caught by writing the assertion the UI-SPEC table already specified.

## Decisions Made

See `key-decisions` in the frontmatter. The four a later plan should not re-litigate:

- **The row body is inert by construction.** Do not add an `InkWell` to make the row "feel tappable" — the absence of a press flash is the T-12-51 mitigation, not an oversight.
- **Three rows always.** Do not hide the PC and Extension rows when the socket is down. The disconnected sentence IS the row's state.
- **The Extension row's trailing slot is empty in every state.** Do not "fix" the missing spinner during a check — the slot table's "always on the Extension row" is the governing rule.
- **`_lastPcTarget` is widget-local and must stay that way.** Persisting it would let a stale target survive a restart, which is exactly what the server's `stale` guard refuses.

## Issues Encountered

- **`pumpAndSettle` cannot be used on any screen carrying `ConnectionHeaderChip`.** Its 500ms `Timer.periodic` calls `setState`, so a frame is always scheduled and settling never terminates. Every wait in the new suite is an explicit `pump(Duration)`, and every test ends with `_unmount` so the ticker is cancelled before the binding's pending-timer check — the `browser_screen_test` / `media_screen_test` discipline, followed here rather than rediscovered.
- **The matrix has 17 rows for 15 kinds.** `available` appears three times (App, PC, Extension) because the Extension's display-only variant is a distinct value with `sizeBytes: null` and `actionable: false`. The completeness test compares *kinds*, so the extra rows are coverage rather than duplication.

## Verification Results

| Gate | Result |
|------|--------|
| `flutter test test/update/updates_screen_test.dart` | **49 passed** |
| `flutter test test/settings_screen_test.dart` | **14 passed** (8 pre-existing + 6 new) |
| `flutter test` (whole app) | **832 passed** (was 777) |
| `flutter analyze` | **No issues found** |
| `grep -c 'FilledButton' lib/update/updates_screen.dart` | 1 (exactly one, as required) |
| `grep -c 'UpdatesScreen' lib/settings/settings_screen.dart` | 2 (>= 1) |
| `grep -c 'Semantics' lib/settings/settings_screen.dart` | 2 (>= 1) |
| `grep -c 'Positioned(' lib/hub/hub_screen.dart` | 1 (>= 1) |
| Shipped Settings `Version` row | unchanged (asserted by test, not only by diff) |
| Hub `IconButton` size / colour / icon | unchanged; the dot is a non-participating overlay |
| Row states covered by a widget test | 15 / 15 kinds, 17 / 17 matrix rows |
| Row count in `serverDisconnected` and `couldNotCheck` | exactly 3 in both |
| Row height across `available` / `downloading` / `failed` | identical (`getRect`) |
| `Retry` widgets on a feed failure | exactly 1, inside `CheckFooter` |

### Row-state rendering coverage (SC3)

| Matrix row | Rendered subtitle asserted | Trailing slot asserted |
|------------|---------------------------|------------------------|
| `checking` (App, PC) | `Checking…` | busy spinner |
| `checking` (Extension) | `Checking…` | empty |
| `upToDate` (all three) | `Up to date · {i}` | empty |
| `available` (App, PC) | `{i} → {l} · {s}` | `Update` |
| `available` (Extension) | `{i} → {l} · updates with your PC` | empty |
| `downloading` (App, PC) | `Downloading… {p}%` | determinate arc, value == pct/100 |
| `verifying` (App, PC) | `Checking the download…` | busy spinner |
| `installing` (App, PC) | `Installing…` | busy spinner |
| `restarting` (PC) | `Restarting on your PC…` | busy spinner |
| `failed` × 5 codes | the five closed sentences | `Retry` |
| `couldNotCheck` | `Couldn't check` | empty |
| `serverDisconnected` (PC, Extension) | `Connect to your PC to check` | empty |
| `serverTooOld` (PC, Extension) | the one shared sentence | empty |
| `pcDidNotReturn` (PC) | `PC didn't come back — …` | `Retry` |
| `extensionNeverConnected` | `Not connected — open your browser` | empty |
| `extensionNeedsBrowserRestart` | `Restart your browser to finish updating` | empty |
| `unknownVersion` | `Version unknown` | empty |

## Known Stubs

None. Every widget is wired to the real 12-14 providers; the stub notifier exists only inside the test file.

`SC4` (the physical-device install confirmation) is asserted here only as far as a widget test can reach: the sheet opens, dismisses and routes correctly. The system-owned `PackageInstaller` dialog and the real grant flow are observable only on hardware and belong to 12-18's UAT, which the plan already scopes that way.

## Threat Flags

None beyond the plan's register. Every mitigation it assigns to this plan's files is now asserted:

- **T-12-06** — no `kError`, no code, status, path, URL or hash is representable; swept across all 30 matrix cases.
- **T-12-51** — the row body has no recognizer; tapping it fires nothing.
- **T-12-52** — versions render verbatim; an unparseable one reads `Version unknown`.
- **T-12-53** — the sheet states what the grant does; no polling and no auto-resume, asserted on both dismiss paths.
- **T-12-54** — no animation on a row state change; the state types are value-equal upstream.
- **T-12-01** — recorded for continuity: the PC `Update` sends a version string and nothing else; a test asserts the target the screen can send is the one the feed resolved.

## User Setup Required

None.

## Next Phase Readiness

Wave 6's remaining plan is `12-17` (the PC settings window's own Updates section). It depends on `12-12`, not on this plan, so it is unblocked independently.

For `12-17` and `12-18`:

- The seven fixed sentences the PC surface must reuse are the `kFail*` and `kSubtitle*` consts in `lib/update/updates_screen.dart`. Quote them so the two surfaces never describe one state with two sets of words (D-11).
- `formatSize` and `formatAgo` in `lib/update/update_format.dart` produce the `{size}` and `{ago}` fragments the PC section also needs.
- The launch path still owes `quietLaunchCheck()` one call — the screen calls `ensureChecked()` on mount, which is a different trigger. Wiring it is `12-18`'s bump-and-verify scope.

## Self-Check: PASSED

All five files exist on disk and all four commits (`f6c4bdc`, `eef00dd`, `f2bea22`, `f1f70a6`) are present in `git log`.
