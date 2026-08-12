---
phase: 07-server-shell-dashboard-polish
plan: 12
subsystem: ui
tags: [flutter, riverpod, settings, trackpad, shared_preferences, D-11, D-12, SRV-03]

# Dependency graph
requires:
  - phase: 07-server-shell-dashboard-polish
    provides: "07-09/07-10's theme/tokens.dart (kBg/kSurface/kHairline/kText/kMuted/kAccent/kError), settings/haptics.dart (hapticsEnabledProvider), and the sensitivity.dart cached-hot-path house pattern this plan clones for scroll_direction.dart"
provides:
  - "settings/scroll_direction.dart — scrollDirectionProvider (shared_preferences, default Natural) + a hot-path-cached scrollReversedCached the trackpad driver reads (mirrors haptics.dart's bindHapticsCache/debugHapticsCached shape)"
  - "trackpad_driver.dart — an optional scrollReversed seam (bool Function()): Reversed flips the y-scroll sign on both the live ScrollIntent path and the momentum-loop ticks; omitted/false defaults to Natural (zero behavior change for every pre-D-11 caller)"
  - "trackpad_screen.dart wired end-to-end: bindScrollDirectionCache(ref) installed in initState, scrollReversed: () => scrollReversedCached passed into TrackpadDriver — the Settings toggle has real effect, not just an isolated driver seam"
  - "settings/settings_screen.dart — SettingsScreen: Paired PCs (+Revoke, +add/switch-PC), Pointer sensitivity, Scroll direction, Haptic feedback, Accent (static Blue swatch) — reachable offline, UI-SPEC §5 order"
  - "screens/device_list_screen.dart repurposed (doc-only) to the add/switch-PC surface; home role moves to HubScreen in 07-13"
affects:
  - "07-13 (dashboard) wires the app-bar gear to SettingsScreen — this plan is the destination, not the entry point"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Cached-pref hot-path gate cloned a third time (sensitivity -> haptics -> scroll_direction): store+Notifier+top-level cache+bind function, all in one file, screen installs the listener once via listenManual(fireImmediately: true)"
    - "Optional injected seam with a static default method (TrackpadDriver._naturalScroll) so a new driver capability ships without touching every existing test call site"
    - "InMemorySharedPreferencesAsync (shared_preferences_platform_interface, promoted from transitive to explicit dev_dependency) as the widget-test seam for screens that watch multiple real SharedPreferencesAsync-backed providers at once"

key-files:
  created:
    - app/remote_control/lib/settings/scroll_direction.dart
    - app/remote_control/lib/settings/settings_screen.dart
    - app/remote_control/test/scroll_direction_test.dart
    - app/remote_control/test/settings_screen_test.dart
  modified:
    - app/remote_control/lib/trackpad/trackpad_driver.dart
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/lib/screens/device_list_screen.dart
    - app/remote_control/pubspec.yaml

key-decisions:
  - "[Rule 2 - Missing Critical] trackpad_screen.dart wiring (bindScrollDirectionCache + the scrollReversed seam pass-through) was NOT in the plan's files_modified list, but the plan's own must_haves truth ('flips the trackpad scroll sign in the driver') requires the pref to have real effect in the live app, not just an isolated driver-level seam. Added it — mirrors main.dart's bindHapticsCache install exactly."
  - "TrackpadDriver's scrollReversed param is OPTIONAL (defaults to a static _naturalScroll = false), not required like sensitivity's — this keeps every pre-existing call site (trackpad_driver_test.dart's Harness) compiling unchanged, satisfying the plan's own constraint that only scroll_direction.dart + trackpad_driver.dart were named for Task 1"
  - "scroll_direction.dart's hot-path cache lives in the module itself (mirrors haptics.dart), not as a screen-local double (unlike sensitivity.dart) — the driver's seam reads scrollReversedCached directly, so no per-screen cache field was needed"
  - "shared_preferences_platform_interface promoted from transitive to explicit dev_dependency (same pinned 2.4.2, zero new downloads) so settings_screen_test.dart can seed InMemorySharedPreferencesAsync — SettingsScreen watches three real SharedPreferencesAsync-backed providers simultaneously, which throws 'platform instance must be set' in a bare flutter_test environment otherwise"
  - "Paired-PCs group sources rows from deviceListProvider filtered to .paired (not a new store query) — the same list/store machinery the (repurposed) device list screen already uses, keeping the offline-capable contract intact"

patterns-established:
  - "TDD RED/GREEN on a driver seam addition without a UI: test(07-12) proves the compile-time absence of scrollReversed, feat(07-12) adds it with a backward-compatible default"

requirements-completed: [UI-02, SRV-03]

# Metrics
duration: ~25min
completed: 2026-07-13
---

# Phase 7 Plan 12: App Settings Screen + Scroll-Direction Pref Summary

**A new App Settings screen (Paired PCs + Revoke, Pointer sensitivity, Scroll direction, Haptic feedback, fixed Blue accent) plus a persisted scroll-direction pref that actually flips the live trackpad's scroll sign via a cached hot-path seam on TrackpadDriver.**

## Performance

- **Duration:** ~25 min
- **Tasks:** 2/2
- **Files created:** 4 (2 lib, 2 test)
- **Files modified:** 4 (trackpad_driver.dart, trackpad_screen.dart, device_list_screen.dart, pubspec.yaml)
- **Tests:** 11 new (6 scroll_direction_test.dart, 5 settings_screen_test.dart) — full suite 343/343 green
- **Analyze:** `flutter analyze lib` and `flutter analyze lib test` both clean

## Accomplishments

- `settings/scroll_direction.dart`: a shared_preferences-backed `scrollDirectionProvider` (default Natural) cloning the `sensitivity.dart`/`haptics.dart` house pattern, with a top-level hot-path cache (`scrollReversedCached`) and `bindScrollDirectionCache(ref)` install function.
- `TrackpadDriver` grew an optional `scrollReversed` seam: Reversed flips the y-scroll sign on both the live `ScrollIntent` path and the momentum-loop's decaying ticks, leaving the magnitude/decay math untouched — proven via TDD (RED commit `2df96e6` -> GREEN commit `9a020fb`).
- `trackpad_screen.dart` wired end-to-end (Rule 2 auto-fix — see Deviations) so the Settings toggle has real, live effect on the trackpad's scroll direction, not just an isolated driver capability.
- `settings/settings_screen.dart`: the full App Settings screen per 07-UI-SPEC §5 — Paired PCs (with destructive Revoke + add/switch-PC entry), Pointer sensitivity (reused seam), Scroll direction (segmented Natural/Reversed), Haptic feedback (Switch), and a static non-interactive Accent swatch (D-12, no picker).
- Revoke removes the device from `DeviceStore` + deletes its token, and disconnects the live session when the row is the connected target — the client-side half of SRV-03; server-side revoke is 07-08.
- `device_list_screen.dart`'s doc comment updated to its new add/switch-PC role (behavior unchanged — home role moves to `HubScreen` in 07-13).

## Task Commits

1. **Task 1a (TDD RED): scroll-direction driver sign-gate test** - `2df96e6` (test)
2. **Task 1b (TDD GREEN): TrackpadDriver scrollReversed seam** - `9a020fb` (feat)
3. **Task 1c: wire the cache into TrackpadScreen (Rule 2)** - `e2e0b77` (feat)
4. **Task 2: SettingsScreen + paired-PC Revoke + device-list doc update + widget test** - `85a98ec` (feat)

## Files Created/Modified

- `app/remote_control/lib/settings/scroll_direction.dart` - Store + Notifier + hot-path cache for the D-11 scroll-direction pref
- `app/remote_control/lib/trackpad/trackpad_driver.dart` - Optional `scrollReversed` seam on the scroll-sign emission (ScrollIntent + momentum tick)
- `app/remote_control/lib/trackpad/trackpad_screen.dart` - `bindScrollDirectionCache(ref)` + `scrollReversed: () => scrollReversedCached` wired into the driver constructor
- `app/remote_control/lib/settings/settings_screen.dart` - `SettingsScreen`: five UI-SPEC §5 groups
- `app/remote_control/lib/screens/device_list_screen.dart` - Doc comment only: repurposed to add/switch-PC surface
- `app/remote_control/pubspec.yaml` - `shared_preferences_platform_interface` promoted transitive -> explicit dev_dependency
- `app/remote_control/test/scroll_direction_test.dart` - Hot-path cache + driver sign-gate unit tests
- `app/remote_control/test/settings_screen_test.dart` - Widget tests: group order, non-interactive Accent, Revoke confirm/cancel/confirm flows, add/switch-PC navigation

## Decisions Made

See `key-decisions` in frontmatter. Summarized: (1) trackpad_screen.dart wiring was added under Rule 2 even though not in the plan's named file list, because the plan's own truth statement requires the pref to have real effect; (2) the driver's new seam is optional/defaulted so no existing test call site needed touching; (3) the hot-path cache lives in scroll_direction.dart itself (haptics-style), not a screen-local double; (4) `shared_preferences_platform_interface` promoted to an explicit dev_dependency (zero new downloads, same pinned version) to unblock a widget test that watches three real prefs-backed providers at once.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Wired scroll_direction cache into trackpad_screen.dart**
- **Found during:** Task 1, after implementing the driver seam
- **Issue:** The plan's Task 1 `<files>` list named only `scroll_direction.dart` and `trackpad_driver.dart`. Neither this plan nor 07-13 (checked ahead of time) touches `trackpad_screen.dart` anywhere in their file lists, yet the plan's own `must_haves.truths` states "Scroll direction is a persisted pref that flips the trackpad scroll sign in the driver (D-11)" — without wiring the live screen, the Settings toggle (Task 2) would have zero effect on the actual trackpad, a functional stub masquerading as a complete feature.
- **Fix:** Added `bindScrollDirectionCache(ref)` to `TrackpadScreen.initState` (mirrors the `bindHapticsCache` install pattern) and passed `scrollReversed: () => scrollReversedCached` into the `TrackpadDriver` constructor.
- **Files modified:** `app/remote_control/lib/trackpad/trackpad_screen.dart`
- **Verification:** `flutter analyze lib` clean; full `flutter test` suite (343 tests) green — no existing trackpad test broke.
- **Commit:** `e2e0b77`

**2. [Rule 1 - Bug] Two lint fixes surfaced by `flutter analyze lib test`**
- **Found during:** Task 2 verification pass
- **Issue:** `unnecessary_underscores` (two `(_, __) {}` closures in `scroll_direction_test.dart`) and `depend_on_referenced_packages` (test file imported `shared_preferences_platform_interface` without it being a declared dependency).
- **Fix:** Changed `__` to `_` in the two closures; promoted `shared_preferences_platform_interface` from transitive to an explicit `^2.4.2` dev_dependency in `pubspec.yaml` (same resolved version — confirmed via `flutter pub get` output "from transitive dependency to dev dependency", no new download).
- **Files modified:** `app/remote_control/test/scroll_direction_test.dart`, `app/remote_control/pubspec.yaml`, `app/remote_control/pubspec.lock`
- **Verification:** `flutter analyze lib test` clean (0 issues).
- **Commit:** `e2e0b77` (lint fix), `85a98ec` (pubspec change)

---

**Total deviations:** 2 auto-fixed (1 missing-critical end-to-end wiring, 1 lint/dependency hygiene)
**Impact on plan:** Both were necessary to satisfy the plan's own truth statements and keep `flutter analyze` clean. No scope creep beyond what the plan's acceptance criteria already implied.

## Testing

- `test/scroll_direction_test.dart` (6 tests): hot-path cache default + `debugScrollReversedCached` determinism; driver Natural/Reversed sign flip on the live `ScrollIntent` path; no-seam-provided default (backward compat); live re-read per intent; momentum-loop sign flip with magnitude untouched.
- `test/settings_screen_test.dart` (5 tests): the five groups render in UI-SPEC §5 order (position-based ordering check); the Accent swatch has no `InkWell`/`GestureDetector` ancestor (non-interactive by construction); tapping Revoke opens the confirm dialog and Cancel leaves the store untouched; confirming Revoke removes the device + deletes its token; the add/switch-PC entry pushes `DeviceListScreen`.
- Full suite: `flutter test` — 343/343 green (no regressions across the whole app).
- `flutter analyze lib` and `flutter analyze lib test` — both clean.

## TDD Gate Compliance

Task 1 followed RED -> GREEN with distinct commits:
- RED: `test(07-12)` `2df96e6` — driver compile failure on the not-yet-existing `scrollReversed` param
- GREEN: `feat(07-12)` `9a020fb` — seam added, all pre-existing `trackpad_driver_test.dart` cases still pass

No REFACTOR commit needed (the GREEN implementation was minimal and clean on first pass). Task 2 was `type="auto"` (non-TDD) per the plan.

## Known Stubs

None. The Settings screen's Paired PCs group renders real data from `deviceListProvider`/`DeviceStore`; Revoke performs a real local mutation + disconnect; scroll direction has real, live effect on the trackpad (see Deviation 1).

## Issues Encountered

None beyond the two auto-fixes documented above.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- 07-13 (dashboard) can wire its app-bar gear directly to `SettingsScreen` — the destination is complete and functions offline.
- No migration debt: `trackpad_screen.dart`'s scroll-direction wiring is already live, so 07-13 does not need to revisit it.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-13*

## Self-Check: PASSED
