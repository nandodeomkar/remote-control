---
phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
plan: 01
subsystem: app/settings
tags: [flutter, riverpod, shared_preferences, persistence, position-store]
requires: []
provides:
  - "bubble_position.dart: Edge enum, BubblePosition model, BubblePositionStore, BubblePositionNotifier, bubblePositionStoreProvider, bubblePositionProvider, kBubblePositionPrefsKey"
  - "window_position.dart: WindowPosition model (unset sentinel), WindowPositionStore, WindowPositionNotifier, windowPositionStoreProvider, windowPositionProvider, kWindowPositionPrefsKey"
affects:
  - "08-03 (TrackpadBubble drag/edge-snap → bubblePositionProvider)"
  - "08-04 (FloatingTrackpadWindow header-drag → windowPositionProvider)"
tech-stack:
  added: []
  patterns:
    - "Two-half store+Notifier persistence (SensitivityStore/SensitivityNotifier clone)"
    - "Clamped/degrading load + fire-and-forget save over SharedPreferencesAsync"
    - "Value-equal model to suppress no-op Riverpod rebuilds"
key-files:
  created:
    - app/remote_control/lib/settings/bubble_position.dart
    - app/remote_control/lib/settings/window_position.dart
    - app/remote_control/test/bubble_position_test.dart
    - app/remote_control/test/window_position_test.dart
  modified: []
decisions:
  - "Serialized each position as a single {..} JSON string (dart:convert), mirroring device_store's composite-value idiom, rather than two flat prefs keys"
  - "Unknown/absent edge string degrades the WHOLE bubble position to the default (right/70%), not just the edge field — matches the plan's 'corrupt value degrades to default' behavior line"
  - "WindowPosition uses a bool isSet sentinel via two const constructors (.at / .unset) rather than a nullable model, so the value stays const-constructible and value-equal"
metrics:
  duration: ~9min
  tasks: 2
  files: 4
  completed: 2026-07-15
---

# Phase 8 Plan 01: Position Stores Summary

Two independent, non-secret position stores + Riverpod notifiers — `(edge, yFraction)` for the bubble (default right/70%) and `(x, y)` with an unset sentinel for the floating window — cloning the proven SensitivityStore two-half house pattern, with clamped/degrading reads that can never place either off-screen.

## What Was Built

- **`lib/settings/bubble_position.dart`** — `enum Edge { left, right }`, value-equal `BubblePosition(edge, yFraction)` (default `(right, 0.70)` = D8-02), `BubblePositionStore` with an injectable `SharedPreferencesAsync`, JSON `{edge, yFraction}` serialization, `try/on Object` degrade-to-default load, `yFraction.clamp(0,1)` on read+write, and a Riverpod 3 `BubblePositionNotifier` (sync-seed default → async load → fire-and-forget `set`). Providers: `bubblePositionStoreProvider`, `bubblePositionProvider`, key `kBubblePositionPrefsKey = 'bubble.position'`.
- **`lib/settings/window_position.dart`** — value-equal `WindowPosition` with a `bool isSet` sentinel (`WindowPosition.at(x, y)` / `WindowPosition.unset()`), so 08-04 anchors from the bubble spot on first-ever open (D8-03). `WindowPositionStore` mirrors the bubble store: JSON `{x, y}`, degrade-to-unset on corrupt/missing, clamp `[0,1]` on read+write. Providers `windowPositionStoreProvider`, `windowPositionProvider`, key `kWindowPositionPrefsKey = 'window.position'` — fully independent of the bubble store (SC4).
- **Tests** — 13 bubble + 12 window cases: round-trip, default/unset-default, corrupt-JSON / wrong-type / unknown-edge degrade, above/below clamp on read, clamp on write, notifier sync-seed + `set`, and value-equality. Backed by `InMemorySharedPreferencesAsync` so the store's real default adapter works with no plugin channel (mirrors `settings_screen_test.dart`).

## How It Works

Each store reads its key as a JSON string via `dart:convert`, decodes the small map, clamps fractions to `[0,1]`, and wraps the whole body in `try { … } on Object { return <default> }` (mirror of `SensitivityStore.load` L50–58). A corrupt, wrong-typed, or unknown-edge read therefore returns the documented default (bubble → right/70%, window → unset sentinel) and never throws — satisfying threat T-08-01 (a tampered pref can never place the bubble/window off-screen). Writes clamp the same fractions, so an out-of-range value can never even be persisted. The notifiers seed synchronously so the first frame has a valid position, then replace it with the loaded value; `set()` updates state immediately and persists `unawaited` (a failed write costs persistence, never responsiveness).

## Deviations from Plan

None — plan executed exactly as written. Both tasks followed the `tdd="true"` RED → GREEN flow (failing test committed first, implementation second).

## Verification

- `flutter test test/bubble_position_test.dart test/window_position_test.dart` → **25/25 green**.
- `flutter analyze` on all four files → **No issues found**.
- All four `must_haves.truths` proven by named tests: round-trip (both), default/unset-default, corrupt-degrade, and read+write clamp.

## TDD Gate Compliance

Both tasks produced the mandatory gate sequence in git history:
- Task 1: `test(08-01)` 6e119bf (RED) → `feat(08-01)` a190e6a (GREEN).
- Task 2: `test(08-01)` 51dd375 (RED) → `feat(08-01)` 230db87 (GREEN).

No REFACTOR commit was needed (implementations were clean on first green).

## Known Stubs

None — both stores are fully wired to `shared_preferences`; no placeholder data or mock sources. The providers have no consumers yet (that is 08-03 / 08-04 in Wave 2), which is the intended leaf-first sequencing, not a stub.

## Commits

- `6e119bf` test(08-01): add failing bubble position store + notifier tests
- `a190e6a` feat(08-01): implement bubble position store + notifier
- `51dd375` test(08-01): add failing window position store + notifier tests
- `230db87` feat(08-01): implement window position store + notifier

## Self-Check: PASSED

- FOUND: app/remote_control/lib/settings/bubble_position.dart
- FOUND: app/remote_control/lib/settings/window_position.dart
- FOUND: app/remote_control/test/bubble_position_test.dart
- FOUND: app/remote_control/test/window_position_test.dart
- FOUND commits: 6e119bf, a190e6a, 51dd375, 230db87
