---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 08
subsystem: app
tags: [dart, flutter, riverpod, store, bookmarks, local-navigation, optimistic-ui]

# Dependency graph
requires:
  - phase: 11-07
    provides: BmNode plus the six Bm*Msg classes the snapshot parks and the commands send
  - phase: 11-01
    provides: TabInfo.bookmarked — the tri-state the optimistic overlay sits on top of
provides:
  - BookmarksSnapshot on ConnectionService, parked from both bm.changed and the bm.list reply, with zero payload logging
  - bookmarks_store.dart — BookmarksViewState (flat nodes + derived children index + nav state), BookmarksNotifier (drill-down, back stack, folders-first order, stale-folder self-heal, four commands), bookmarksStateProvider
  - TabsViewState.optimisticStars / bookmarkedFor and TabsNotifier.star / unstar — the D-12 optimistic-then-reconcile overlay
affects: [11-10, 11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Notifier-owned mutable navigation state copied (unmodifiable) into every emitted view, so a pushed snapshot cannot move the user and no state value aliases the notifier's containers"
    - "Optimistic-then-reconcile overlay keyed off snapshot IDENTITY (not value equality), so a value-equal-but-new snapshot still reconciles and an unrelated changes ping never does"
    - "Stable partition (two buckets, concatenated) instead of a comparator, when the sort key has ties whose original order is meaningful"

key-files:
  created:
    - app/remote_control/lib/browser/bookmarks_store.dart
    - app/remote_control/test/browser/bookmarks_store_test.dart
  modified:
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/browser/tabs_store.dart
    - app/remote_control/test/browser/tabs_store_test.dart

key-decisions:
  - "childrenByParent is excluded from BookmarksViewState's == / hashCode because it is a pure function of nodes — comparing it on every changes ping would be redundant work with no possible extra signal; a code comment says so at the exclusion site"
  - "BookmarksViewState.isDeletable is a public static, not a private function: the row widget (11-10) needs the same per-row rule the hasDeletableChild hint line uses, and one shared predicate is the only way the two cannot drift"
  - "A folder carrying no count is treated as NOT deletable — the conservative read, since count absent means the phone cannot prove the folder is empty"
  - "TabsViewState.hashCode uses Object.hashAllUnordered over per-entry hashes so two equal overlays built in different insertion orders hash alike (Dart maps have no order-independent hash and Object.hashAll over entries would not be stable)"

patterns-established:
  - "Identity-tracked reconciliation: when a service parks a fresh object per push, `identical()` against the last-seen object is the precise definition of 'new authoritative data', and value equality is actively wrong for it"

requirements-completed: []

# Metrics
duration: 18min
completed: 2026-07-29
---

# Phase 11 Plan 08: Bookmarks client state layer Summary

**The phone now owns the bookmark tree's navigation entirely by itself — drilling in and backing out send nothing on the wire, a pushed snapshot cannot move the user, and a folder that vanishes heals to the root silently — while the tab star flips instantly and reconciles against the next authoritative snapshot by object identity, so an unrelated volume ping can never steal the flip.**

## Performance

- **Duration:** 18 min
- **Started:** 2026-07-29T17:44:00Z
- **Completed:** 2026-07-29T18:02:00Z
- **Tasks:** 3
- **Files created/modified:** 5

## Accomplishments

- `BookmarksSnapshot` parks from **both** legs — the `bm.changed` push and the `bm.list` reply — in the exact `TabsSnapshot` shape: hand-rolled element-wise `==`, no `package:collection`, and both new arms carry the explicit "NO payload logging anywhere (SPEC §12 — bookmark titles are browsing data)" note with zero log calls anywhere near them (T-11-02).
- **`BookmarksNotifier` is the app's first store with navigation state.** `_currentFolderId` and `_backStack` live on the notifier, not the snapshot, so `bm.changed` landing mid-browse is invisible to the user (D-04). Proven directly: drill into a folder, push a snapshot that adds a node to that same folder, and `currentFolderId` / `depth` are unchanged while the new child appears.
- **The virtual root is not special-cased in navigation, only in display.** `'0'` is the `parentId` every Chrome root carries, so listing its children *is* listing the roots (D-08) — no synthetic node, no hard-coded root list, nothing in the tree unreachable. `currentFolderTitle` and `currentFolderTruncated` are the only two places `'0'` is treated as "not a real node", and both return the depth-0 answer.
- **Folders-first ordering is a stable partition, not a comparator.** Two buckets filled in one pass and concatenated — `List.sort` is not stable in Dart, so a comparator could silently reorder same-kind siblings and break the "preserves Chrome's own per-parent index order" promise. The test pushes a folder emitted *after* two links and asserts `['12', '10', '11']`.
- **The D-12 overlay reconciles on identity.** `_onChange` compares `_service.tabsSnapshot` against `_lastSnapshot` with `identical()`. Two tests pin the two failure modes value-equality would produce: a new snapshot that *disagrees* with the flip (and is value-equal to its predecessor) still wins, and a bare `changes` ping over the unchanged snapshot object does not clear the flip.
- **The UNKNOWN third state survives the overlay.** `bookmarkedFor` returns `optimisticStars[tab.id] ?? tab.bookmarked`, so a null stays null and the widget layer renders no star rather than an empty one (D-11, T-11-01) — asserted for all three of `true` / `false` / `null`.
- Suite went **547 → 567 tests**, +20 (12 new bookmarks-store, 8 new tabs-store), `flutter analyze` clean, the theme-token and icon guards green.

## Task Commits

1. **Task 1: Park BookmarksSnapshot on ConnectionService** — `48e8cd8` (feat)
2. **Task 2: BookmarksNotifier — local folder navigation over the flat node list** — `3f42107` (feat)
3. **Task 3: Optimistic star overlay on TabsNotifier** — `cfeecd6` (feat)

## Files Created/Modified

- `app/remote_control/lib/net/connection_service.dart` — `class BookmarksSnapshot` (after `TabsSnapshot`), `_bookmarksSnapshot` field, `bookmarksSnapshot` getter, and the `BmChangedMsg` / `BmListMsg` parking arms placed immediately after the `TabsListMsg` arm
- `app/remote_control/lib/browser/bookmarks_store.dart` **(new)** — `BookmarksViewState` with `currentChildren` / `currentFolderTitle` / `depth` / `currentFolderTruncated` / `hasDeletableChild` / `isDeletable`, `BookmarksNotifier` with `primeList` / `enterFolder` / `goBack` / `open` / `remove`, and `bookmarksStateProvider`
- `app/remote_control/lib/browser/tabs_store.dart` — `optimisticStars` + `bookmarkedFor` on the state, `_optimistic` + `_lastSnapshot` on the notifier, identity reconciliation in `_onChange`, and `star` / `unstar`
- `app/remote_control/test/browser/bookmarks_store_test.dart` **(new)** — 12 tests over the fake-service seam in a bare `ProviderContainer`
- `app/remote_control/test/browser/tabs_store_test.dart` — 8 added tests (4 view-equality/tri-state, 6 overlay behaviour; 11 → 19 total in the file)

## Decisions Made

- **`childrenByParent` is deliberately outside `==` and `hashCode`.** It is built from `nodes` by a deterministic one-pass index in the same `_view()` call, so two states with equal `nodes` always have equal indexes. Comparing it would walk the whole tree a second time on every ping to learn nothing. The exclusion is commented at the site so a future reader does not "fix" it.
- **`isDeletable` is a public static on the state, not a private helper.** 11-10 renders per-row `onLongPress: null` using exactly the rule `hasDeletableChild` uses for the hint line. If the row widget re-derived it, the hint could promise an affordance no row offers (or vice versa). One predicate, one place, both callers.
- **A folder with `count == null` is not deletable.** The extension always emits `count` on folders, so this is a defensive branch — but the safe default when the phone cannot prove a folder is empty is to offer nothing, since D-14's whole point is that a subtree wipe must be structurally unreachable.
- **`Object.hashAllUnordered` for the overlay's hash contribution.** Dart's `Map` has no order-independent `hashCode`, and hashing `entries` in iteration order would make two `==`-equal overlays (same pairs, different insertion order) hash differently — a `==`/`hashCode` contract violation the moment a state lands in a `Set` or `Map` key. Per-entry `Object.hash(k, v)` folded through `hashAllUnordered` fixes it.
- **`build()` resets `_optimistic` and `_lastSnapshot`.** The notifier is rebuilt when `connectionServiceProvider` changes — a new service means a new snapshot lineage, so carrying a stale identity or a stale flip across that boundary would be a bug the plan did not name but the reset costs two lines.

## Deviations from Plan

**None** — all three tasks executed as written. Two clarifications worth recording, neither a behavioural change:

- **The `grep -c "package:collection"` → 0 criterion on `connection_service.dart` cannot return 0 and never could.** The file already contained the *phrase* `no-package:collection rule` in `TabsSnapshot`'s doc comment before this plan (line 162), and the `BookmarksSnapshot` doc comment written here mirrors that voice, so the count is 2. **There is no `package:collection` import and no use of it** — the criterion's intent (hand-rolled equality, 06-03 rule) is fully met, and rewording the doc comment to dodge a literal grep would have made the two sibling classes read differently for no reason. The same criterion on `bookmarks_store.dart` returns a genuine **0**.
- **Test counts came in above the floor.** The plan asked for "9 or more" bookmarks-store tests (12 delivered — the extra three cover the connected:false hint state, the D-04 consecutive-opens command shape, and the two same-named-but-different `truncated` flags) and "6 or more" added tabs-store tests (8 delivered).

## Issues Encountered

None. Every acceptance gate passed first run; no auto-fix was needed on any task.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-02 (info disclosure, parking arms) | mitigate | Both new arms carry the explicit no-payload-logging comment; `grep` for `print` / `debugPrint` / any logger inside them returns nothing, and neither arm touches `msg.nodes` other than to move the list into the snapshot |
| T-11-13 (tampering, PC-supplied titles) | mitigate | Titles are opaque display strings throughout: never interpolated into a command, never parsed, never used as a map key, never used to resolve a node. Every lookup in the store (`currentFolderTitle`, `currentFolderTruncated`, the self-heal probe, the children index) keys on `id` / `parentId` only |
| T-11-04 (tampering, remove blast radius) | mitigate | The store exposes only `remove(String nodeId)` — no bulk form, no recursive form, no list overload. `hasDeletableChild` / `isDeletable` are unit-tested to return false for a non-empty folder and for a locked node |
| T-11-06 (tampering, unstar blast radius) | transfer | `TabsNotifier.unstar` opens no UI (`grep -c showDialog` = 0); the confirm gate is 11-11's widget-layer responsibility and `unstar` is only ever called after it resolves |
| T-11-01 (info disclosure, tri-state fidelity) | mitigate | `bookmarkedFor` returns `null` for UNKNOWN rather than coercing to `false`; asserted for all three states with and without an overlay entry |
| T-11-SC (supply chain) | mitigate | Zero new pub packages; `pubspec.yaml` untouched; `package:collection` grep-gated at 0 in the new store file |

No new security-relevant surface beyond the register — no threat flags.

## Known Stubs

None. Every symbol this plan declares is implemented and unit-exercised. The widget layer (`browser_segment.dart`, `bookmarks_section.dart`, `bookmark_confirm.dart`, the star slot in `_TabRow`, `BrowserSegmentBar`) is absent **by design** — this plan is explicitly widget-free and 11-09 onward owns it. `primeList()` is currently uncalled in `lib/` for the same reason: D-03 fires it from the segment `onSelect` that 11-09 builds.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **11-09/11-10 (the segment bar and the bookmarks section) are unblocked.** `bookmarksStateProvider` exposes everything the UI-SPEC's Component 2 needs: `connected` for the shared install hint, `nodes.isEmpty` for `No bookmarks yet.`, `currentChildren.isEmpty` for `This folder is empty.`, `truncated` for the header count line, `currentFolderTruncated` for the inline folder line, `depth` for the folder bar and `PopScope(canPop: depth == 0)`, `currentFolderTitle` for its label, and `hasDeletableChild` for the long-press hint.
- **The per-row long-press gate is already written:** `BookmarksViewState.isDeletable(node)` — use it directly rather than re-deriving the rule.
- **11-11 (the star slot) needs `state.bookmarkedFor(tab)`, not `tab.bookmarked`.** Reading the raw field would render the authoritative value and lose the optimistic flip entirely. The `null` return means render NO star slot.
- **Carry-forward:** `primeList()` must be called from the segment's `onSelect`, guarded by a `bool _bmPrimed`, **not** from `initState` (D-03) — the analog `TabsNotifier.primeList()` is an `initState` call and copying that shape here would prime the bookmark tree for users who never open the segment.

## Self-Check: PASSED

All five claimed files exist on disk and carry the claimed symbols: `class BookmarksSnapshot` ×1, `BookmarksSnapshot? get bookmarksSnapshot` ×1, `msg is BmChangedMsg` / `msg is BmListMsg` ×2, `class BookmarksNotifier extends Notifier<BookmarksViewState>` ×1, `bookmarksStateProvider` ×1, `package:collection` ×0 in `bookmarks_store.dart`, `optimisticStars` ×8 (field, default, `bookmarkedFor`, `==` ×3, `hashCode`, `_view`), `identical(` ×1, `Map<int, bool>.unmodifiable` ×1, `BmStarMsg`/`BmUnstarMsg` ×2, `showDialog` ×0. All three task commits (`48e8cd8`, `3f42107`, `cfeecd6`) are present in git history on `master`.

Verification re-run at plan close: `flutter analyze` **No issues found!**; `flutter test` **567 passed / 0 failed**; `flutter test test/browser/` green with the pre-existing 33 browser tests untouched; `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` **2 passed**.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
