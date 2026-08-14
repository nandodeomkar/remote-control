---
phase: 13-summon-shell-bar
plan: 07
subsystem: flutter-app-shell
tags: [summon, back-guard, pushGuarded, source-guard, SUM-04, D-13-16, T-13-13, T-13-02]
status: complete

requires:
  - "13-01: SummonBackGuard, SummonScope, SummonGuardScope, SummonShellController"
  - "13-02: SummonShell at MaterialApp.builder, and the guarded `home:` route in main.dart"
  - "13-06: the microtask-deferred lower in summon_back_guard.dart (left untouched)"
provides:
  - "pushGuarded<T> — the one seam every page push in lib/ goes through"
  - "test/push_sites_guard_test.dart — the source scan that fails the build on a bare page-route construction outside lib/shell/"
  - "The rule that guard coverage is enforced by the build rather than remembered by the author"
affects:
  - "Phase 14/15 (raised trackpad, raised keyboard): a new screen is guarded by construction — pushing it any other way reds the build"
  - "Phase 16 (bubble retirement): bubble_scaffold.dart's push is already converted, so deleting the file removes a call site rather than an exception"
  - "Plan 13-09 (the QR bar suppressor): pairing_dialog.dart's push is now pushGuarded<PairQrData>; the suppressor wraps that call, it does not replace it"

tech-stack:
  added: []
  patterns:
    - "One central minting helper per cross-cutting requirement, plus a source scan that makes bypassing it a build failure"
    - "A guard allowlist exempts a DIRECTORY by path prefix, never a line number that drifts on the next edit"
    - "Every exemption carries a written reason, asserted by its own test case"
    - "A test host mounts the production shell only for the case that needs it — fidelity is scoped to the assertion, because the shell reserves 56px and shortens a lazily-built ListView"

key-files:
  created:
    - "app/remote_control/test/push_sites_guard_test.dart"
  modified:
    - "app/remote_control/lib/shell/summon_back_guard.dart"
    - "app/remote_control/lib/hub/hub_screen.dart"
    - "app/remote_control/lib/settings/settings_screen.dart"
    - "app/remote_control/lib/screens/device_list_screen.dart"
    - "app/remote_control/lib/screens/pairing_dialog.dart"
    - "app/remote_control/lib/widgets/bubble_scaffold.dart"
    - "app/remote_control/test/hub_offline_test.dart"
    - "app/remote_control/test/settings_screen_test.dart"

key-decisions:
  - "lib/shell/ is exempt by path prefix, not by summon_back_guard.dart:<line>. A line number is invalidated by the next edit to the file it names, and the failure mode of a stale allowlist entry is that the guard starts reporting its own helper as an offender — which gets 'fixed' by loosening the pattern."
  - "The two failing test hosts got the shell only for their pushing case, not for the whole file. Mounting it in the shared host reserved kSummonBarHeight, shortened the lazily-built settings ListView, and reds two unrelated Accent-chip cases that never lay out the row they assert on."
  - "spec.builder receives the hub's context rather than the route's, because pushGuarded takes an eager Widget. Every entry in kHubTiles discards its argument, so the destination widget is byte-identical; recorded here rather than absorbed, because a future context-using tile builder would read the hub's route scope."

requirements-completed: [SUM-04]

coverage:
  - id: D1
    description: "Every page route pushed anywhere in lib/ is wrapped in a back guard — Settings, Device List, Updates, the QR screen and the bubble's expand now dismiss a raised surface on back exactly as the hub and the nine tool screens do"
    requirement: "SUM-04"
    verification:
      - kind: command
        ref: "test \"$(grep -rc 'pushGuarded' lib/ | grep -vc ':0')\" -eq 6"
        status: pass
      - kind: unit
        ref: "test/push_sites_guard_test.dart#every page route in lib/ is built through pushGuarded (D-13-16)"
        status: pass
    human_judgment: false
  - id: D2
    description: "One central helper mints the guarded route, so a future screen is guarded by construction rather than by remembering"
    requirement: "SUM-04"
    verification:
      - kind: unit
        ref: "test/push_sites_guard_test.dart#every page route in lib/ is built through pushGuarded (D-13-16)"
        status: pass
    human_judgment: false
  - id: D3
    description: "A source-scanning test fails the build when a bare page route is constructed outside the shell directory, with a written reason per allowlist entry (D-13-16)"
    verification:
      - kind: unit
        ref: "test/push_sites_guard_test.dart#every guard exemption carries a written reason"
        status: pass
      - kind: command
        ref: "manual falsification — bare push re-introduced at lib/screens/device_list_screen.dart:95, guard RED naming that path:line; tree restored"
        status: pass
    human_judgment: false
  - id: D4
    description: "The helper is generic and preserves its route's return type, so the pairing sheet's QR push still receives its scanned value"
    requirement: "SUM-04"
    verification:
      - kind: unit
        ref: "test/pairing_flow_test.dart + test/qr_scan_pairing_test.dart — 25 cases, all pass"
        status: pass
    human_judgment: false
  - id: D5
    description: "The bubble's own push is converted too, so the bar and the bubble coexist correctly for the three phases they overlap"
    verification:
      - kind: unit
        ref: "test/bubble_scaffold_test.dart (in the 956-green full suite)"
        status: pass
    human_judgment: false
  - id: D6
    description: "On hardware: back on Settings, Device List, Updates and the QR scanner actually lowers a raised surface before popping the route"
    verification: []
    human_judgment: true
    rationale: "The widget suite proves the guard is mounted on every route and that the ownership predicate behaves (13-05/13-06). Whether the gesture feels right on those four screens specifically is a UAT observation, not an assertion."

metrics:
  duration: ~35min
  completed: 2026-08-14
  tasks: 2
  commits: 2
  files: 9

actuals:
  tokens: 5900
  tasks: 2
  commits: 2
---

# Phase 13 Plan 07: One Guarded Push Seam Summary

**Every page route in the app is now minted by one helper, and a bare construction outside `lib/shell/` fails the build with the offender's path and line — closing the half of SUM-04 that failed silently on four screens with no error and no log.**

## Performance

- **Duration:** ~35 min
- **Completed:** 2026-08-14
- **Tasks:** 2
- **Files created:** 1, modified: 8

## Task Commits

1. **Task 1: One central guarded-push seam, and all seven call sites through it** — `d6600db` (feat)
2. **Task 2: A source-scanning guard so a future un-guarded push fails the build** — `748921d` (test)

## The seven converted push sites

| # | File | Line (pre) | Destination | Note |
|---|---|---|---|---|
| 1 | `lib/hub/hub_screen.dart` | 285 | the 9 tool screens (central tile-open) | `BubbleScaffold` wrapper kept **inside** the guard |
| 2 | `lib/hub/hub_screen.dart` | 299 | `SettingsScreen` | gear tap, reachable offline (D-11) |
| 3 | `lib/settings/settings_screen.dart` | 219 | `DeviceListScreen` | the add/switch-PC row |
| 4 | `lib/settings/settings_screen.dart` | 660 | `UpdatesScreen` | keeps its `hapticTick()` |
| 5 | `lib/screens/device_list_screen.dart` | 94 | `HubScreen` (re-push) | the one hub push, two call sites above it |
| 6 | `lib/screens/pairing_dialog.dart` | 360 | `QrScanScreen` | **generic** — `pushGuarded<PairQrData>`, awaited value drives pairing |
| 7 | `lib/widgets/bubble_scaffold.dart` | 118 | `TrackpadScreen` via `⤢` | dies in Phase 16; correct for the three phases the bar and bubble overlap |

The root route was already guarded (`main.dart:126`, 13-02) and is not a push, so it needed no change. **Six modal sites stay deliberately un-guarded** — with a dialog or sheet open it is the topmost route, so back closes it first and the raised surface is untouched. The helper's doc comment states this so nobody wires guards into them.

## What Was Built

**Task 1 — `pushGuarded<T>` (`d6600db`).** Eleven lines of code under forty of doc comment:

```dart
Future<T?> pushGuarded<T>(BuildContext context, Widget screen) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(builder: (_) => SummonBackGuard(child: screen)),
  );
}
```

The doc comment names SUM-04, states that a push skipping the helper silently loses back-dismiss on that route with no error and no log, points at `test/push_sites_guard_test.dart` as the enforcement, and records that modal routes are intentionally outside it.

`T` is the route's return type and the returned future is the route's own, so the pairing sheet still awaits its `PairQrData`. No cast was introduced anywhere; the QR site went from `push<PairQrData>(MaterialPageRoute(...))` to `pushGuarded<PairQrData>(sheetContext, const QrScanScreen())`.

**13-06's microtask deferral was not touched.** `scheduleMicrotask(controller.lower)` and its comment block are byte-identical in the committed diff — the helper was added *beside* the guard, not inside its callback.

**Task 2 — `test/push_sites_guard_test.dart` (`748921d`).** `icons_guard_test.dart` copied wholesale with the pattern swapped, preserving all four load-bearing mechanics: the relative `Directory('lib')` handle, `replaceAll('\\', '/')` for Windows, the `trimmed.startsWith('//')` comment skip, and a `path:line` allowlist whose failure message prints every offender.

Two departures from the template, both deliberate:

- **The allowlist is non-empty by design.** `lib/shell/` is exempt **by path prefix**, because it holds `pushGuarded` — the one legitimate construction site. Both exemption maps are `Map<String, String>` (location → written reason) rather than bare `List<String>`, and a second test case asserts every reason is non-empty. A bare exemption is how a guard rots: the next reader cannot tell a deliberate carve-out from a silenced failure.
- **The failure message is actionable.** It names `pushGuarded(context, screen)` with its file, and states the consequence in one sentence — back keeps popping the screen with the surface still raised, with no error and no log.

## The guard has teeth — both mutations run and recorded

Each mutation was applied to the tree, run, then reverted. `git diff` over `lib/` is empty afterwards; the committed tree is byte-identical.

| Mutation | Result |
|---|---|
| `device_list_screen.dart`: `pushGuarded<void>(context, const HubScreen())` → **the bare `Navigator.push(MaterialPageRoute<void>(...))` form** | **RED**, offender printed as `lib/screens/device_list_screen.dart:95 -> MaterialPageRoute<void>(builder: (_) => const HubScreen()),` with the full pushGuarded/silent-failure message. **This is the confirmation the plan asked for.** |
| `device_list_screen.dart`: a comment line reading `// MUTATION-B PROBE: prose naming MaterialPageRoute<void>( must not trip` | **GREEN** — the comment skip holds, so prose about the banned construct does not self-trip the guard |

The first mutation is the one that matters: a guard nobody has seen fail is a guard nobody knows works. It failed at the right file, the right line, and with a message that tells the next person what to type instead.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Two test hosts pushed a guarded route with no `SummonScope` above them**

- **Found during:** Task 1, on the first full-suite run.
- **Issue:** `hub_offline_test.dart` ("the settings gear stays tappable and opens SettingsScreen") and `settings_screen_test.dart` ("the add/switch-PC entry pushes the device list screen") both host a bare `const MaterialApp(home: …)`. Once their push went through `pushGuarded`, the `SummonBackGuard` it wraps the route in called `SummonScope.of(context)` in `didChangeDependencies` and hit `Failed assertion: 'scope != null'` — *"No SummonScope above this context"* (`summon_scope.dart:236`). Production cannot reach this: `main.dart:114-126` mounts `SummonShell` at `MaterialApp.builder`. The hosts were simply less faithful than production, and only the push exposed it.
- **Fix:** each host gained the production `builder: (context, child) => SummonShell(child: child!)` shape — **for the pushing case only**, via an opt-in flag (`_host(store, shell: true)`) and a separate `_shellHost(store)` respectively.
- **Files modified:** `test/hub_offline_test.dart`, `test/settings_screen_test.dart` — neither in the plan's `files_modified`. No production code changed for this.
- **Verification:** both cases green; full suite green.
- **Committed in:** `d6600db`

**2. [Rule 1 - Bug in the first fix] Mounting the shell in the *shared* host reds two unrelated cases**

- **Found during:** Task 1, immediately after deviation 1's first attempt.
- **Issue:** putting the shell in `settings_screen_test.dart`'s shared `_host` reserved `kSummonBarHeight` (56px) at the bottom, which shortened the settings screen's **lazily-built** `ListView`. Two Accent-chip cases that run at the default 800x600 viewport then failed with `Found 0 widgets with text "Blue"` and a `Bad state: No element` — the row they assert on was no longer laid out at all. The blast radius of "make the host faithful" was nine unrelated tests.
- **Fix:** the shell is scoped to the one case that pushes. The other eight settings cases and the two hub tile cases render at exactly the geometry they did before this plan.
- **Verification:** `flutter test test/hub_offline_test.dart test/settings_screen_test.dart` — 16 cases, all pass.
- **Committed in:** `d6600db`

---

**Total deviations:** 2 auto-fixed (1 blocking test-host constraint, 1 bug in that fix's first form).
**Impact on plan:** No production behaviour changed beyond the push mechanism, and no assertion anywhere was weakened, dropped or re-pinned. The second deviation is worth reading as a rule rather than an incident: test-host fidelity is not free, and raising it globally to satisfy one case silently changes the geometry every other case was written against.

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/push_sites_guard_test.dart` | 2 cases, both passed |
| `flutter test test/icons_guard_test.dart test/theme_tokens_guard_test.dart` | 2 cases, both passed — the sibling guards are unaffected |
| `flutter test test/pairing_flow_test.dart test/qr_scan_pairing_test.dart` | 25 tests, all passed — the awaited QR value still flows |
| `flutter test test/hub_offline_test.dart test/settings_screen_test.dart` | 16 tests, all passed |
| `flutter test` (full suite) | **956 passed** (954 before this plan + 2) |
| `flutter analyze --no-fatal-infos` | No issues found |
| `test "$(grep -rc 'pushGuarded' lib/ \| grep -vc ':0')" -eq 6` | succeeds — helper file + 5 call-site files |
| `git diff -- lib/hub/hub_screen.dart` | `BubbleScaffold` still present inside the guarded builder; `kHubTiles` untouched |
| `git diff` over `lib/` after both falsification mutations | empty |

## Success Criteria

- [x] All seven page pushes in `lib/` go through one guarded seam, each listed above with its file and destination
- [x] The pairing sheet's QR push still returns its scanned value — generic, no cast
- [x] A bare page-route construction outside the shell directory fails the build with an actionable message, proved red by hand
- [x] Modal routes remain deliberately un-guarded, stated in the helper's doc comment

## Requirements Completed

- **SUM-04** — the silent half closed: back now dismisses a raised surface on Settings, Device List, Updates, the QR screen and the bubble's expand, and a future screen inherits that by construction

## Threat Mitigations

| Threat ID | Disposition | Status |
|---|---|---|
| T-13-13 (un-guarded page routes) | mitigate | **Mitigated** — all seven pushes routed through `pushGuarded`, plus the source scan that fails the build on a bare construction outside `lib/shell/`. Proved to have teeth by a recorded red run naming `device_list_screen.dart:95`. |
| T-13-02 (the QR route's awaited value) | mitigate | **Mitigated** — the helper is generic and returns the route's own future; `pairing_flow_test.dart` + `qr_scan_pairing_test.dart` (25 cases) re-run green as the regression net. No cast introduced. |
| T-13-SC (package-manager installs) | accept | No installs; `pubspec.yaml` unchanged. |

## Threat Flags

None — this plan adds no network endpoint, no auth path, no file access and no schema change. It changes how routes are constructed, not what any screen does.

## Known Stubs

None. The helper is real, all seven sites call it, and the guard scans the real `lib/` tree.

## Notes for Next Phase

- **Plan 13-09** adds the bar suppressor to `pairing_dialog.dart`'s QR push. That push is now `pushGuarded<PairQrData>(sheetContext, const QrScanScreen())` — the suppressor wraps this call, it does not replace it, and the type parameter must survive.
- **Phase 16** deletes `bubble_scaffold.dart`. Its push is already converted, so the deletion removes a call site rather than an allowlist exception; the guard needs no edit.
- **A new screen added in Phase 14/15 is guarded by construction.** If someone types a bare page route, the build reds with the file, the line and the helper to call. That is the whole point of D-13-16 — the previous failure mode had no signal at all.
- **If `lib/shell/` is ever split**, update `kPushSitesGuardExemptPrefixes` rather than adding a line-number entry. The prefix form exists because line numbers drift.

## Self-Check: PASSED

`test/push_sites_guard_test.dart` exists on disk; all eight modified files exist; both commits (`d6600db`, `748921d`) are present in git history. Neither commit deletes a tracked file (`git diff --diff-filter=D` over the pair is empty).

---
*Phase: 13-summon-shell-bar*
*Completed: 2026-08-14*
