---
phase: 07-server-shell-dashboard-polish
plan: 09
subsystem: app
tags: [flutter, riverpod, theme, tokens, haptics, wakelock, keep-awake, shared_preferences, UI-02]

# Dependency graph
requires:
  - phase: 04-trackpad
    provides: "settings/sensitivity.dart cached-pref store+Notifier house pattern cloned by haptics.dart; trackpad_screen listenManual sensitivity-cache seam mirrored by bindHapticsCache"
provides:
  - "theme/tokens.dart — kBg/kSurface/kHairline/kText/kMuted/kAccent/kError palette consts + buildAppTheme() (single D-12 source of truth)"
  - "settings/haptics.dart — hapticsEnabledProvider (shared_preferences, default ON) + cached-pref hapticTick()/hapticTickMedium() gate + bindHapticsCache()"
  - "widgets/keep_awake.dart — ref-counted KeepAwake wrapper (acquire/release) + shared keepAwake singleton over WakelockPlus"
affects:
  - "07-10 migrates every screen palette block onto tokens.dart, routes ~15 haptic call sites through hapticTick()/hapticTickMedium(), and reroutes trackpad+presenter through keepAwake.acquire()/release()"
  - "07-12/07-13 dashboard + settings screens consume buildAppTheme() and the haptics toggle"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Interface-first UI-02 foundation: three shared primitives shipped as NEW files with unit tests, touching zero existing screen — migration deferred to 07-10"
    - "Hot-path cached-pref gate: a top-level cached bool updated from one listenManual listener; the gate reads only the cache, never ref.read per tap (mirrors sensitivity)"
    - "Ref-counted wrapper over a global platform flag: injectable enable/disable callbacks make the transitions unit-testable without the platform channel"

key-files:
  created:
    - app/remote_control/lib/theme/tokens.dart
    - app/remote_control/lib/settings/haptics.dart
    - app/remote_control/lib/widgets/keep_awake.dart
    - app/remote_control/test/haptics_gate_test.dart
    - app/remote_control/test/keep_awake_test.dart
  modified: []

key-decisions:
  - "bindHapticsCache uses ref.listenManual(fireImmediately: true), not ref.listen — the trackpad sensitivity-cache seam is the house pattern; WidgetRef.listen in Riverpod 3 does not accept fireImmediately"
  - "Test-only @visibleForTesting debugHapticsCached getter/setter drives the gate deterministically, so haptics_gate_test proves fire/silent without a prefs backend or provider container"
  - "HapticFeedback calls are captured in tests via a mock SystemChannels.platform method-call handler filtering method == 'HapticFeedback.vibrate' (arg carries the impact type)"
  - "keep_awake exposes both the injectable KeepAwake class (tested with spies) and a process-wide keepAwake singleton so trackpad+presenter share ONE ref-count (the actual Pitfall-8 fix)"

patterns-established:
  - "Capturing platform-channel side effects in a pure unit test via setMockMethodCallHandler on SystemChannels.platform"
  - "Injectable-callback seam on a wrapper over a global platform singleton (WakelockPlus) to unit-test state transitions off-device"

requirements-completed: [UI-02]

# Metrics
duration: 12min
completed: 2026-07-12
---

# Phase 7 Plan 09: UI-02 Polish Foundation Primitives Summary

**Three new Flutter primitives — one palette/theme token source (D-12), a cached-pref haptics gate hapticTick()/hapticTickMedium() (D-13), and a ref-counted keep-awake wrapper that pre-empts the Pitfall-8 quick-bar leak (D-14) — each unit-proven, touching zero existing screen.**

## Performance

- **Duration:** 12 min
- **Tasks:** 3/3
- **Files created:** 5 (3 lib + 2 test)
- **Tests:** 9 (5 haptics gate, 4 keep-awake) — all green
- **Analyze:** clean on all three lib files

## What Was Built

### Task 1 — `theme/tokens.dart` (D-12)
The single source of truth for the locked dark-minimal palette, replacing the `const Color _bg/…` block copy-pasted across every screen. Exports seven public consts (`kBg #0E0F12`, `kSurface #16181D`, `kHairline #2A2D34`, `kText #E6E8EB`, `kMuted #6B7280`, `kAccent #4C8DFF`, `kError #FF6B6B`) plus `buildAppTheme()`, which lifts the inline `ThemeData` (Brightness.dark, `kBg` scaffold, accent-seeded dark ColorScheme) verbatim from `main.dart`. Consolidation only — no redesign, no screen touched.

### Task 2 — `settings/haptics.dart` (D-13, TDD)
Clones the `sensitivity.dart` two-half store+Notifier pattern: `HapticsStore` over `SharedPreferencesAsync` (key `haptics.enabled`, default ON, try/catch degrade-to-ON), `HapticsNotifier extends Notifier<bool>` (synchronous ON seed, async load, persist-through `set`), and `hapticsEnabledProvider`. The hot-path contract is enforced by a top-level cached `_hapticsCached` bool that `bindHapticsCache(ref)` keeps in sync via one `listenManual` listener; `hapticTick()` (lightImpact) and `hapticTickMedium()` (mediumImpact, for the power screen) read only that cache — never `ref.read` per tap.

### Task 3 — `widgets/keep_awake.dart` (D-14, TDD)
A ref-counted `KeepAwake` wrapper over `WakelockPlus`: `acquire()` enables only on the 0→1 transition, `release()` disables only on the final 1→0, and `release()` at count 0 is an underflow-guarded no-op. The enable/disable calls are injectable so the transitions are unit-tested with spies (no platform channel). A process-wide `keepAwake` singleton lets trackpad + presenter share one count — the concrete fix for the Pitfall-8 leak the new quick-bar nav path (`Presenter → Trackpad → back`) would otherwise introduce, shipped before the quick-bar exists.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `fireImmediately` not accepted on `WidgetRef.listen`**
- **Found during:** Task 2 (GREEN)
- **Issue:** The plan's suggested `ref.listen(...fireImmediately: true)` failed to compile — in Riverpod 3, `WidgetRef.listen` has no `fireImmediately` parameter.
- **Fix:** Switched `bindHapticsCache` to `ref.listenManual<bool>(..., fireImmediately: true)` — the exact seam `trackpad_screen.dart` already uses for its sensitivity cache.
- **Files modified:** `app/remote_control/lib/settings/haptics.dart`
- **Commit:** f6c7b9c

## Testing

- `test/haptics_gate_test.dart` (5 tests): cache ON → lightImpact/mediumImpact fires exactly once; cache OFF → silent; default cache is ON. HapticFeedback captured via a mock `SystemChannels.platform` handler.
- `test/keep_awake_test.dart` (4 tests): enable only 0→1; disable only final 1→0; release at 0 no-op; re-acquire after full release re-enables. Injected enable/disable spies.
- Verification commands green: `flutter test test/haptics_gate_test.dart test/keep_awake_test.dart` and `flutter analyze lib/theme/tokens.dart lib/settings/haptics.dart lib/widgets/keep_awake.dart`.

## TDD Gate Compliance

Both TDD tasks followed RED → GREEN with distinct commits:
- Task 2: `test(07-09)` c417c13 (RED) → `feat(07-09)` f6c7b9c (GREEN)
- Task 3: `test(07-09)` 730ca81 (RED) → `feat(07-09)` 3b6bd9c (GREEN)

No REFACTOR commits needed (implementations were minimal and clean on first pass).

## Known Stubs

None. All three primitives are fully functional; they are intentionally not yet wired into screens (migration is the explicitly-scoped 07-10 plan, not a stub).

## Commits

- cfb0389 — feat(07-09): tokens.dart single palette source + buildAppTheme() (D-12)
- c417c13 — test(07-09): add failing test for haptics gate (RED)
- f6c7b9c — feat(07-09): haptics gate cached-pref hapticTick()/hapticTickMedium() (GREEN)
- 730ca81 — test(07-09): add failing test for keep-awake ref-count (RED)
- 3b6bd9c — feat(07-09): ref-counted keep-awake wrapper over WakelockPlus (GREEN)

## Self-Check: PASSED

All 5 created files present on disk; all 5 task commits present in git history.
