---
phase: 12-in-app-updates
plan: 14
subsystem: updates
tags: [dart, flutter, riverpod3, state-machine, providers, ui-contract, security]

# Dependency graph
requires:
  - phase: 12-in-app-updates (12-05)
    provides: UpdateCheckMsg / UpdateStatusMsg / UpdateApplyMsg / UpdateProgressMsg / LastUpdate Dart codecs
  - phase: 12-in-app-updates (12-07)
    provides: SemVer.tryParse / isNewer, UpdateCacheStore + isStale, formatAgo / formatSize
  - phase: 12-in-app-updates (12-08)
    provides: ApkInstaller MethodChannel (canInstall / install / outcomes)
  - phase: 12-in-app-updates (12-10)
    provides: fetchLatest / Release / ReleaseAsset / assetWithPrefix, downloadApk / verifyOrDelete / DownloadError
provides:
  - "ConnectionService update seam: UpdateSnapshot (+ UpdateStatusSnapshot / UpdateProgressSnapshot), updateSnapshot getter, reconnectAttempt getter, sendUpdateCheck() / sendUpdateApply(String), kUnknownTypeErrCode"
  - "app_version.dart split: packageInfoProvider (one PackageInfo lookup) -> appBareVersionProvider + appVersionProvider"
  - "UpdateRowState — the whole UI-SPEC row-state matrix as one value-equal type over UpdateRowKind"
  - "UpdateFailure — the five renderable D-11 codes (busy and downgrade are not representable)"
  - "UpdatesViewState + CheckFooterState, updatesStateProvider (check / quietLaunchCheck / ensureChecked / updateApp / updatePc / retryPcReturn)"
  - "updateWireProvider, updateCacheStateProvider, updateBadgeProvider + the pure badgeLit()"
  - "Injectable seams: releaseFetcherProvider, apkDownloaderProvider, apkVerifierProvider, apkInstallerProvider, updateClockProvider"
affects: [12-15, 12-16, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "The subscribe-and-re-snapshot store (bookmarks_store.dart) applied to a derived state machine: ref.listen, never ref.watch, for anything whose change must not discard in-flight session state"
    - "Enumerable state: one immutable class + one exhaustive enum, so a switch in the widget layer cannot miss a state and one operator== covers every variant"
    - "Security by non-representability: the two swallowed error codes are absent from the failure enum, so they cannot be rendered by any future code path"
    - "Timer-free timeouts: a policy question ('did the PC come back?') answered from an existing FSM counter rather than a new timer"

key-files:
  created:
    - app/remote_control/lib/update/update_providers.dart
    - app/remote_control/test/update/update_providers_test.dart
  modified:
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/settings/app_version.dart
    - app/remote_control/test/connection_service_test.dart
    - app/remote_control/test/app_version_test.dart

key-decisions:
  - "UpdateRowState is ONE value-equal class over an exhaustive UpdateRowKind enum rather than fifteen sealed subclasses. The enum is the matrix (a switch over it is exhaustive for 12-15), one hand-written operator== covers every variant, and the plan's constructor spellings — upToDate(installed), available(installed, latest, sizeBytes), downloading(pct), failed(code) — survive verbatim as named const constructors."
  - "`actionable` is a FIELD of the state, not a widget-layer decision. That turns D-18 ('the Extension row never has an enabled action') from a property of a widget tree into a fact a unit test asserts about a value, and gives the Extension's display-only `available` a distinct, unequal identity from the App/PC one."
  - "UpdateFailure omits `busy` and `downgrade` entirely. mapWireError swallows busy (returns null) and degrades downgrade to installer with the real code logged. Because neither is representable, no future code path can render them — which is the T-12-06 mitigation stated as a type, not as a convention."
  - "pcDidNotReturn (D-25) reads ConnectionService.reconnectAttempt — the EXISTING reconnect FSM's own counter — at a threshold of 5 (its 1/2/4/8/10s ladder ~= 25s). D-17 forbids a second reconnect path, and a threshold on a counter that already exists adds no timer, no scheduler and no bespoke retry."
  - "The rows derive from the LIVE feed only; the cache feeds the badge. update_cache.dart deliberately stores no asset sizes, and the `available` subtitle owes the user a size before a 70 MB download starts (D-08) — so a cache-only latest can light the badge but can never produce an Update button."
  - "The notifier uses ref.listen (not ref.watch) for the version and cache providers. A rebuild would discard the in-flight download, the feed result and the apply bookkeeping, none of which is recoverable; those two inputs only ever need to re-derive."
  - "The update snapshot is cleared in _teardownChannel, unlike every other snapshot on the service. The others describe a PC that is still the same PC after a blip; a stale serverVersion is the one value that could make the Updates screen claim a PC is current after the phone was pointed at a different one."
  - "unknownType correlation: the protocol carries no request ids, so an outstanding-check flag set by sendUpdateCheck and cleared by the reply is the correlation. An unknownType refusal of some OTHER future family leaves the update snapshot alone; a test pins both halves."
  - "A cache older than the 24h TTL still lights the badge. update_cache.dart states the same rule from the other side ('the badge keeps its last known answer instead of blanking'); staleness drives WHEN to check again, never WHAT to display."

patterns-established:
  - "Provider-level effect seams (fetch / download / verify / install / clock) as typedef'd function providers — the entire state machine runs offline with no HTTP, no socket and no platform channel"
  - "A real ConnectionService over fake seams inside the provider test, so the connection-service arms and the derivation are proven together rather than against a mock of one another"
  - "A source-reading test as the guard for absence rules (no StateNotifier, no Timer) — the same shape as the phase's grep gates, but executable"

requirements-completed: [D-05, D-06, D-07, D-08, D-11, D-13, D-17, D-18, D-19, D-22, D-23, D-25, D-26, SC2, SC3]

# Metrics
duration: 35min
completed: 2026-08-04
---

# Phase 12 Plan 14: Update Providers Summary

**The UI-SPEC row-state matrix is now an enumerable, value-equal Dart type driven by four injected inputs — so every state the Updates screen can render is reachable, constructible and tested before a single pixel exists.**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3
- **Files modified:** 6 (2 created, 4 modified)
- **Tests added:** 60 (10 connection-service, 5 app-version, 50 provider — but note the 50 include the 5 named below)

## Accomplishments

- **The whole matrix is one type.** `UpdateRowState` covers all fifteen states with a hand-written `operator ==`, an exhaustive `UpdateRowKind`, and named const constructors that read exactly like the plan's spellings. A widget test in 12-15 can now drive any row into any state with one `const` expression.
- **`available` has exactly one producer.** `_compare` is the only function in the file that can return it, and it refuses on three grounds before it can: an unparseable installed version, an unparseable or absent latest, and a release that published no asset for that component. `9.9.9-evil`, `latest`, `1.5` and `''` are each pinned to `unknownVersion` by test (D-26 / T-12-18).
- **The two swallowed codes are not representable.** `UpdateFailure` has five members. `busy` maps to `null` (log it, change nothing — a test asserts the state object is *identical by value* before and after a busy push), and `downgrade` maps to `installer` with the real code logged. No HTTP status, path, URL, hash or exception class has a field to travel in.
- **One feed failure is screen-scoped.** All three rows read `couldNotCheck` simultaneously and *none* of them is actionable — the single retry lives in the footer, exactly as the D-22 reading in the UI-SPEC resolves it.
- **The App row's asymmetry is enforced, not documented.** With no socket at all, the PC and Extension rows are `serverDisconnected` while the App row is a live, actionable `available` — its version comes from the package and its feed from the internet.
- **The PC update is confirmed by reconnection and by nothing else.** `updatePc` sends one `update.apply {target}`, schedules nothing, and the row rides `restarting` -> socket drop -> FSM redial -> auth -> automatic re-check -> `upToDate`. A test walks that whole path. `pcDidNotReturn` falls out of the FSM's own attempt counter.
- **The badge tells the truth offline.** `badgeLit` is pure and reads the cache, so it is correct before the Updates screen has ever been opened. It is dark for an absent cache, an unparseable tag on either side, a failed check, no socket and a 1.7 server; it lights for a known-behind app, PC or extension; and it clears the frame the last out-of-date known component reaches `upToDate`.
- **The version identity bug this whole phase exists to prevent stayed prevented.** `packageInfoProvider` resolves `PackageInfo` once; the bare version and the display string are two renderings of that one pair. The bare version is never obtained by picking the formatted string apart, and the About row's output is byte-unchanged.

## Task Commits

1. **Task 1: the connection-service update seam** — `e439c41` (feat)
2. **Task 2: a bare installed-version provider** — `b172d80` (feat)
3. **Task 3: update_providers.dart — the row-state machine and the badge** — `fc965e6` (feat)

## Files Created/Modified

- `app/remote_control/lib/update/update_providers.dart` (new, ~940 lines) — the wire vocabularies, `UpdateRowKind` / `UpdateRowState`, `UpdateFailure` / `mapWireError`, `CheckFooterState`, `UpdatesViewState`, the five effect seams, `UpdateCacheNotifier`, `UpdateWireNotifier`, `badgeLit` / `updateBadgeProvider`, `UpdatesNotifier` and `updatesStateProvider`
- `app/remote_control/test/update/update_providers_test.dart` (new) — 50 tests over a real `ConnectionService` on fake seams
- `app/remote_control/lib/net/connection_service.dart` — `kUnknownTypeErrCode`, the three snapshot classes, `_updateSnapshot` + `_updateCheckOutstanding`, `updateSnapshot` / `reconnectAttempt` getters, `sendUpdateCheck` / `sendUpdateApply`, two push arms, the `unknownType` arm, the teardown clear
- `app/remote_control/test/connection_service_test.dart` — 10 new tests in an `update seam` group
- `app/remote_control/lib/settings/app_version.dart` — `PackageVersion`, `packageInfoProvider`, `appBareVersionProvider`; `appVersionProvider` now composes
- `app/remote_control/test/app_version_test.dart` — 5 new tests for the split

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `ConnectionService.reconnectAttempt` added for D-25**

- **Found during:** Task 3 (planned in Task 1's file)
- **Issue:** D-25 says the row reads "PC didn't come back" *after the reconnect FSM's timeout*, and the plan forbids a second reconnect timer. But the FSM never gives up — it backs off forever — and its attempt counter was not exposed on the service, so there was no timer-free way to know the PC had not returned.
- **Fix:** Exposed the existing `ReconnectFsm.attempt` as `ConnectionService.reconnectAttempt` (a getter over state the FSM already keeps) and thresholded it at `kPcReturnAttempts = 5` in the derivation. No timer, no scheduler, no new dial path.
- **Files modified:** `lib/net/connection_service.dart`, `lib/update/update_providers.dart`
- **Verification:** `the reconnect attempt count is readable — and no NEW timer exists` asserts an apply schedules zero callbacks; `pcDidNotReturn after an apply the PC never came back from (D-25)` walks one drop (`restarting`) then five (`pcDidNotReturn`).
- **Committed in:** `e439c41`, `fc965e6`

**2. [Rule 2 - Missing Critical] The update snapshot is cleared on disconnect**

- **Found during:** Task 1
- **Issue:** The plan says "clear the update snapshot the same way the other snapshots are cleared" — but no other snapshot on the service is cleared at all. `_teardownChannel` left volume/apps/tabs/bookmarks parked, deliberately, because they describe a PC that is still the same PC after a blip. A `serverVersion` is different in kind: it is the answer to "is this PC up to date", and after a PC *update* (which drops the socket by design) or a switch to a different PC it is actively wrong.
- **Fix:** `_teardownChannel` resets `_updateSnapshot` and `_updateCheckOutstanding`, with a comment explaining why this one snapshot diverges from its four siblings.
- **Files modified:** `lib/net/connection_service.dart`
- **Verification:** `the update snapshot is CLEARED when the session drops`.
- **Committed in:** `e439c41`

**3. [Rule 3 - Blocking] `ensureChecked()` added — the screen needs a check trigger that is neither the tap nor the launch check**

- **Found during:** Task 3
- **Issue:** The plan names two check paths: the tapped `check()` and the invisible `quietLaunchCheck()`. Neither can populate the rows when the user opens the Updates screen inside the 24h window (the quiet check is skipped, so no live `Release` exists) — and the rows cannot fall back to the cache, because `update_cache.dart` stores no asset size and the `available` subtitle owes the user one (D-08). Without a third trigger the screen would open on three `unknownVersion` rows.
- **Fix:** `ensureChecked()` runs `check()` only when this session holds no feed result and none is in flight or failed. It is user-intent-triggered (the screen was opened), spends at most one request per open, and no-ops on a screen that already has a result. `build()` itself performs no check, so merely reading the badge never fetches.
- **Files modified:** `lib/update/update_providers.dart`
- **Verification:** `ensureChecked checks once, and not again once a result is held`.
- **Committed in:** `fc965e6`

**4. [Rule 1 - Bug] `AsyncValue.valueOrNull` does not exist in Riverpod 3**

- **Found during:** Task 3
- **Issue:** Three analyzer errors — Riverpod 3 unified the accessor to the nullable `AsyncValue.value`.
- **Fix:** `.valueOrNull` -> `.value` at all three sites.
- **Verification:** `flutter analyze` -> No issues found.
- **Committed in:** `fc965e6`

**5. [Rule 1 - Bug] Two footer assertions compared a UTC `DateTime` to a local one**

- **Found during:** Task 3
- **Issue:** `UpdateCacheState.lastCheckAt` round-trips through `DateTime.fromMillisecondsSinceEpoch`, which returns a LOCAL-zone `DateTime`. The same instant compared unequal to the `DateTime.utc(...)` the test constructed (IST, +05:30).
- **Fix:** Both assertions compare `millisecondsSinceEpoch` — the instant — rather than the `DateTime` object, with a comment saying why. No production change: the `{ago}` formatter consumes a `Duration` difference, which is zone-independent.
- **Verification:** Both tests pass; the rest of the suite is unaffected.
- **Committed in:** `fc965e6`

**6. [Rule 3 - Blocking] A doc comment tripped the plan's own grep gate**

- **Found during:** Task 2
- **Issue:** `grep -c "const.*[Vv]ersion.*=.*'[0-9]" app_version.dart` had to be 0, but the file's shipped header explained the anti-constant rule by *spelling* a version constant, and a second sentence named the platform lookup, making `grep -c PackageInfo.fromPlatform` return 2 against a "resolved once" criterion.
- **Fix:** Both sentences reworded to state the rule without spelling the token (the 12-10 precedent), each noting explicitly that the grep must find zero / exactly one. The rationale itself is carried forward intact and extended to the new providers.
- **Verification:** the two greps now return 0 and 1.
- **Committed in:** `b172d80`

---

**Total deviations:** 6 auto-fixed (2 blocking, 1 missing-critical, 3 bugs). No architectural changes, no new dependency, no scope creep. Deviations 1 and 3 are both cases where a decision the plan names ("after its timeout", "row states before a check") had no producer until one was added inside the constraints the plan set.

## Decisions Made

See `key-decisions` in the frontmatter. The four a later plan should not re-litigate:

- **`UpdateRowState` is an enum-plus-fields class, not fifteen sealed subclasses.** 12-15 switches on `state.kind` and reads the fields it needs; the switch is exhaustive, so a state added here cannot be silently unrendered.
- **`actionable` is part of the value.** The renderer must not decide per-row whether to show a button — it shows one when and only when `actionable` is true. That is what makes D-18 structural.
- **The rows need a live feed; the badge needs only the cache.** Do not "improve" the rows by falling back to `lastSeenVersion`: the `available` subtitle promises a size (D-08), and inventing one would break the one thing D-08 exists for.
- **Nothing about an in-flight APK install is persisted.** A test asserts the only two `shared_preferences` keys written across a full download-verify-install run are the two D-07 cache keys.

## Issues Encountered

- **Riverpod rebuild-vs-session-state.** `ref.watch` inside `UpdatesNotifier.build` would re-run `build` on every version/cache change; the in-flight download percentage, the feed result and the apply bookkeeping all live on the notifier and none of them is recoverable. Resolved with `ref.listen` + `ref.read`, so `build` runs exactly once per notifier lifetime and the two derived inputs simply re-publish.
- **`_updateSnapshot` clearing vs. the four sibling snapshots.** Deliberately divergent; see deviation 2. If a future reader "harmonises" it, the Updates screen starts lying about which PC it is describing.
- **`grep -ci 'Timer' lib/update/` is not zero and cannot be.** The hits are `kDownloadConnectTimeout`, `kDownloadStallTimeout` and `.timeout(...)` in `apk_download.dart` (12-10) — the case-insensitive pattern matches "Timeout". The plan's criterion is scoped to "any reconnect-shaped timer added by this phase", so the executable form of it is a test that reads `update_providers.dart` and asserts no `Timer(` or `Timer.` construction exists at all. That test passes.

## Verification Results

| Gate | Result |
|------|--------|
| `flutter test test/connection_service_test.dart` | **32 passed** (21 pre-existing + 11 new) |
| `flutter test test/app_version_test.dart` | **11 passed** |
| `flutter test test/update/update_providers_test.dart` | **50 passed** |
| `flutter test test/update/` | **140 passed** |
| `flutter test` (whole app) | **777 passed** |
| `flutter analyze` | **No issues found** |
| `grep -c 'StateNotifier' lib/update/update_providers.dart` | 0 |
| `grep -cE '\bTimer\s*[(.]' lib/update/update_providers.dart` | 0 |
| `grep -c 'UpdateStatusMsg' lib/net/connection_service.dart` | 3 (>= 1) |
| `grep -c 'UpdateProgressMsg' lib/net/connection_service.dart` | 2 (>= 1) |
| `grep -c "const.*[Vv]ersion.*=.*'[0-9]" lib/settings/app_version.dart` | 0 |
| `grep -c 'PackageInfo.fromPlatform' lib/settings/app_version.dart` | 1 (resolved once) |
| `sendUpdateApply` parameter count | exactly one `String` |
| Row states covered by at least one test | 15 / 15 |

### Row-state coverage (SC3)

| State | Test |
|-------|------|
| `checking` | `checking: all three rows while a tapped check is in flight` |
| `upToDate` | `upToDate / available / availableNoAction across the three rows` |
| `available` (app) | `available (app): the APK size reaches the row before any download` |
| `available` (pc) | `upToDate / available / availableNoAction across the three rows` |
| `available` (ext) | same — asserted `actionable: false`, `sizeBytes: null` |
| `downloading` | PC: from the wire; App: through the real download seam |
| `verifying` | both rows |
| `installing` | both rows |
| `restarting` | `downloading / verifying / installing on the PC row`, and the D-17 walk |
| `failed(code)` | all five codes, plus `lastUpdate{ok:false}` |
| `couldNotCheck` | `ONE feed failure puts all three rows there` |
| `serverDisconnected` | `PC and Extension are gated, the App row is NOT` |
| `serverTooOld` | `blanks BOTH PC-side rows with the same state` |
| `pcDidNotReturn` | `after an apply the PC never came back from (D-25)` |
| `extensionNeverConnected` | `when the server reports no extVersion` |
| `extensionNeedsBrowserRestart` | `when the PC is current and the extension is not (D-18)` |
| `unknownVersion` | unparseable installed, failed lookup, crafted tag, missing asset |

## Known Stubs

None. Every provider is wired to real behaviour behind an overridable seam; nothing returns a hardcoded empty value. The layer is not yet CALLED by any screen — the Updates screen, the Settings nav row and the badge dot are 12-15's scope, which is this plan's stated boundary ("this plan produces no widgets"), not a stub.

## Threat Flags

None beyond the plan's register. Both mitigations the register assigns to this plan's files are implemented and tested:

- **T-12-01** — `sendUpdateApply(String)` and `updatePc(String)` each take exactly one string; a test asserts the encoded payload's key set is exactly `{target}`.
- **T-12-18** — `_compare` is the only producer of `available` and refuses every unparseable input; four crafted tags are pinned to `unknownVersion`.
- **T-12-06** — the failure vocabulary is a five-member enum with no free-text field.
- **T-12-49** — every state type is value-equal, so an unchanged progress tick assigns an equal state and notifies nothing.
- **T-12-50** — no install flag is persisted; a test asserts the written prefs keys.

## User Setup Required

None.

## Next Phase Readiness

Ready for 12-15 (the Updates screen, the Settings nav row and the badge dot):

- `ref.watch(updatesStateProvider)` gives the three rows, the footer and the badge; `switch (row.kind)` is exhaustive and the copy map keys off it plus `row.error`.
- Call `ensureChecked()` from the screen's `initState`, `check()` from the footer button, `updateApp()` from the App row's `Update` (open the explainer sheet on `UpdateAppResult.needsInstallGrant`), `updatePc(latest)` from the PC row's, and `retryPcReturn()` from the `pcDidNotReturn` row's `Retry`.
- `ref.watch(updateBadgeProvider)` is the Settings gear / nav-row dot and does NOT bring the Updates state machine to life — reading it starts no check.
- The launch path (`main.dart` or the hub) should call `quietLaunchCheck()` once; it is silent and cache-gated by design.
- Render `row.actionable`, never a per-row rule of the widget's own — that is how D-18 stays structural.
- `formatSize(row.sizeBytes!)` and `formatAgo(now.difference(footer.lastCheckedAt!))` from 12-07 produce the `{size}` and `{ago}` fragments.

## Self-Check: PASSED

All six files exist on disk (`update_providers.dart`, `update_providers_test.dart`, `connection_service.dart`, `app_version.dart`, `connection_service_test.dart`, `app_version_test.dart`) and all three task commits (`e439c41`, `b172d80`, `fc965e6`) are present in `git log`.
