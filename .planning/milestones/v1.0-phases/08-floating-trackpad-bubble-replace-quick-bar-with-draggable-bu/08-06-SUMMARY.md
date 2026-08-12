---
phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
plan: 06
subsystem: app/hub
tags: [flutter, migration, deletion, uat-gate]
requires:
  - phase: 08-05
    provides: "BubbleScaffold (Stack overlay: body + verbatim UIPI banner + expand-gated bubble/window, showBubble param)"
provides:
  - "Central migration: hub_screen._open wraps every tile destination in BubbleScaffold(showBubble: spec.showBubble) — all 7 tool screens gain the bubble with zero per-screen edits"
  - "Quick-bar deleted outright: quick_bar_scaffold.dart (QuickBarScaffold, _TrackpadQuickBar, 56px reserved slot, kQuickBarLabel/kQuickBarHeight) and quick_bar_test.dart gone"
affects: []
tech-stack:
  added: []
  patterns:
    - "Central wrapper migration: renaming HubTileSpec.showQuickBar -> showBubble and swapping the _open wrap in ONE file migrates all 7 tool screens at once (D8-05)"
key-files:
  created: []
  modified:
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/lib/keyboard/keyboard_screen.dart
    - app/remote_control/lib/widgets/bubble_scaffold.dart
  deleted:
    - app/remote_control/lib/widgets/quick_bar_scaffold.dart
    - app/remote_control/test/quick_bar_test.dart
decisions:
  - "bubble_scaffold.dart doc comments scrubbed of [QuickBarScaffold] dartdoc links in the deletion commit (beyond the plan's file list, Rule 2): deleting the symbol would otherwise leave dangling dartdoc references flagged by the analyzer's comment_references lint posture"
  - "flutter install reuses the last-built APK without rebuilding — on-device UAT of a migration REQUIRES an explicit flutter build apk --release first, or the phone runs the previous build (burned once: stale 07-13 quick-bar APK installed with a fresh install timestamp)"
metrics:
  duration: ~15min (code) + on-device UAT 2026-07-16
  tasks: 2
  files: 5
  completed: 2026-07-16
requirements-completed: [UI-01]
---

# Phase 8 Plan 06: Central BubbleScaffold Migration + Quick-Bar Deletion Summary

**hub_screen._open now wraps every tile destination in `BubbleScaffold(showBubble: spec.showBubble)` — 7 tool screens migrated in one place — and the quick-bar is deleted outright (283 lines removed); on-device UAT gate passed 2026-07-16.**

## What Was Built

- **`lib/hub/hub_screen.dart`** — import swapped `quick_bar_scaffold.dart` → `bubble_scaffold.dart`; `HubTileSpec.showQuickBar` renamed `showBubble` (field, constructor default, Trackpad tile's `showBubble: false`); `_open` wraps every tile destination in `BubbleScaffold(showBubble: spec.showBubble, body: spec.builder(context))`; doc comments updated. The hub's own bare `Scaffold` stays unwrapped (Pitfall 5) — no bubble on the hub, and only the Trackpad tile passes `showBubble: false`.
- **`lib/keyboard/keyboard_screen.dart`** — stale `QuickBarScaffold` doc-comment mention updated to `BubbleScaffold` (comment only).
- **Deletions** — `lib/widgets/quick_bar_scaffold.dart` (`QuickBarScaffold`, `_TrackpadQuickBar`, the 56px reserved Column slot, `kQuickBarLabel`/`kQuickBarHeight`) and `test/quick_bar_test.dart` (superseded by `test/bubble_scaffold_test.dart` from 08-05). No settings toggle to restore it (D8-06); tool screens reclaim the full height.
- **`lib/widgets/bubble_scaffold.dart`** — doc comments scrubbed of now-dangling `[QuickBarScaffold]` dartdoc links (Rule 2, landed with the deletion commit).

## Verification (phase migration gate)

- Grep gate: `QuickBarScaffold` / `showQuickBar` / `quick_bar_scaffold` / `kQuickBar` → **0 files** across `lib/` + `test/`.
- `flutter analyze` → **No issues found**.
- `flutter test` (full suite) → **399 tests, all passed**.

## On-Device UAT Gate (SC5 / whole-phase gate) — PASSED 2026-07-16

Release APK freshly built (`flutter build apk --release`, 50.2MB) and installed on the Xiaomi 25080RABDI (Android 16). Owner confirmed the bubble/window UAT passed, covering the six human-checks:

1. Floating-window cursor latency indistinguishable from the full Trackpad screen — PASS
2. Bubble + window drag on tool screens; kill/relaunch restores both positions independently (fresh-install default bubble right/70%) — PASS
3. Window over the Power screen drags clear; both slide-to-confirm taps land unobstructed — PASS
4. WiFi drop with window open: muted state shown, drag resets, UIPI banner still rides — PASS
5. Collapse/leave while drag-locked on a live session: no stuck mouse button on the PC (CR-01 flush) — PASS
6. Presenter screen: open then close the window; screen stays awake throughout (keepAwake ref-count) — PASS

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing file] bubble_scaffold.dart doc-comment scrub**
- **Found during:** Task 2 (deletion).
- **Issue:** `bubble_scaffold.dart` carried `[QuickBarScaffold]` dartdoc links and a `showQuickBar` mention in comments — dangling once the symbol was deleted (and matched by the plan's own grep gate).
- **Fix:** Rewrote the three doc-comment references to describe "the deleted quick-bar scaffold" instead; no code change.
- **Files modified:** app/remote_control/lib/widgets/bubble_scaffold.dart
- **Verification:** grep gate 0 files; analyzer clean.
- **Committed in:** 371a14a.

### Process note (not a code deviation)

The first on-device install shipped a **stale APK**: `flutter install --release` reused the last-built artifact (dated 07-15, pre-migration) without rebuilding, so the phone showed the old quick-bar despite a fresh install timestamp. Root-caused by comparing the APK file's `LastWriteTime` against the migration commits; fixed with an explicit `flutter build apk --release` before reinstall. Recorded as a decision so future UAT gates always rebuild first.

**Total deviations:** 1 auto-fixed (Rule 2). No scope creep.

## Threat Flags

None new. T-08-09 (build integrity) mitigated as planned: Task 1 rewired the sole importer before Task 2 deleted the file; the grep gate + analyzer prove no dangling reference. T-08-07: the UIPI banner rides every tool screen via `BubbleScaffold`'s verbatim slot — removing the quick-bar removed no security control (confirmed live in UAT check 4).

## Known Stubs

None. Phase 8 is fully wired end-to-end and UAT-gated.

## Commits

- `cc5af0b` feat(08-06): rewire hub_screen to BubbleScaffold; fix keyboard doc comment
- `371a14a` feat(08-06): delete quick-bar outright; scrub dangling doc refs

## Self-Check: PASSED

- FOUND: BubbleScaffold( in app/remote_control/lib/hub/hub_screen.dart (`_open` wrap, key_link pattern `BubbleScaffold\(showBubble:` matches)
- GONE: app/remote_control/lib/widgets/quick_bar_scaffold.dart
- GONE: app/remote_control/test/quick_bar_test.dart
- FOUND commits: cc5af0b, 371a14a
