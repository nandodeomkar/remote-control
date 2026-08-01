---
phase: 12-in-app-updates
plan: 07
subsystem: app-update-core
tags: [semver, version-compare, shared-preferences, cache, formatters, pure-functions, flutter]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 02
    provides: "protocol/fixtures/update/10-version-compare.json — the 15-case cross-language truth table this plan's comparator is written to satisfy, and the real asset byte sizes (69630935 / 5177240 / 13454) the size formatter is calibrated against"
  - phase: 03-pairing-discovery
    provides: "the PrefsKv seam and SharedPrefsKv adapter in lib/store/device_store.dart that the update cache is built on"
  - phase: 11-browser-bookmarks
    provides: "the BrowserSegmentStore shape (namespaced key, degrading read, fire-and-forget save) cloned verbatim by UpdateCacheStore"
provides:
  - "SemVer.tryParse / compareTo / isNewer / normalize — the phone's half of the D-26 version contract, pinned case-for-case to the same fixture the Rust comparator loads"
  - "UpdateCacheState + UpdateCacheStore + isStale — the D-07 24-hour check cadence as a pure predicate over injected time, backed by a prefs seam that degrades on every bad read"
  - "formatAgo / formatSize and their copy consts — the two UI-SPEC formatter tables as deterministic pure functions"
  - "the update. shared_preferences key namespace (update.lastCheckAt, update.lastSeenVersion)"
affects: [12-08, 12-09, 12-11, 12-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A shared-fixture truth table ITERATED by the test rather than restated inline, so a case the fixture gains is a case the test gains"
    - "TTL as a free function over injected `now`, so every boundary is asserted exactly instead of waited on"
    - "Doc comments that state a rule without naming the package it forbids, so the plan's own grep criterion stays a real signal about imports rather than matching prose"

key-files:
  created:
    - app/remote_control/lib/update/version.dart
    - app/remote_control/lib/update/update_cache.dart
    - app/remote_control/lib/update/update_format.dart
    - app/remote_control/test/update/version_test.dart
    - app/remote_control/test/update/update_cache_test.dart
    - app/remote_control/test/update/update_format_test.dart
  modified: []

key-decisions:
  - "The cache stores exactly two values — last check time and last seen version. Asset sizes are NOT cached: the badge does not need one, and the only surface that renders {size} is reached from a live feed fetch (offline that row reads `Couldn't check` per D-22), so cached bytes would be state to keep consistent for nothing"
  - "A future-dated cache entry counts as STALE. A timezone change, an NTP correction or a tampered entry would otherwise pin the cache fresh forever, and `the app stopped checking for updates` is a far worse failure than one extra check"
  - "A negative epoch loads as corrupt (never-checked), not as a very old check — the app cannot have performed a check before 1970"
  - "Exactly 24h is already stale (inclusive boundary), so a launch one day later always gets its check rather than missing by milliseconds"
  - "`update_cache.dart` and `update_format.dart` deliberately do NOT name the packages they forbid; the rules are stated as `never in secure storage` and `no date/byte-formatting package`, because naming them would have made the plan's own grep criteria match prose instead of imports"
  - "SemVer gets ==/hashCode/toString beyond the plan's shape, so tests can compare instances directly and `normalize` is one line over `toString`"

patterns-established:
  - "lib/update/ is pure-and-prefs-only by construction — no widget, no socket, no plugin channel, so the whole module is unit-testable with `flutter test` and no fakes beyond an in-memory map"
  - "Every degraded read in this module returns the same default and logs nothing; an empty cache is the normal first run, not an error"

requirements-completed: [D-07, D-08, D-22, D-26, SC3]

# Metrics
duration: 35min
completed: 2026-08-01
---

# Phase 12 Plan 07: Phone Update Core — Version, Cache, Formatters Summary

**The three decisions that determine whether the phone offers an update at all are now tested pure functions: an integer-tuple version compare pinned case-for-case to the same fixture the Rust side loads, a 24-hour TTL that takes its clock as a parameter, and two copy formatters that match the UI-SPEC tables at every boundary — with no new dependency.**

## Performance

- **Duration:** ~35 min
- **Completed:** 2026-08-01
- **Tasks:** 3 of 3
- **Files created:** 6 (3 source, 3 test) — **0 modified**

## Accomplishments

- **The D-26 comparator agrees with Rust by construction, not by inspection.** `version_test.dart` loads `protocol/fixtures/update/10-version-compare.json` — the exact file `server-core`'s test loads — and iterates its `cases` array, mapping each of the four answers onto a two-directional assertion: `newer` demands `isNewer(a,b)` true *and* `isNewer(b,a)` false, `unknown` demands both false *and* that at least one side actually failed to parse. An asymmetric comparator cannot pass this table, and a case added to the fixture is automatically a case this test enforces.
- **Unknown can never manufacture an offer (T-12-18).** `tryParse` returns `null` for two components, a `-rcN` suffix, a `+build` suffix, the empty string, `latest`, and a 21-digit component that overflows a 64-bit `int` — parsed with `int.tryParse` so overflow yields `null` rather than throwing or saturating to a huge value that would compare as newer. `isNewer` returns `false` the moment either side is `null`.
- **The lexical trap is nailed down in both directions.** `1.10.0` beats `1.9.0` through an explicit `(major, minor, patch)` integer comparison; string comparison and float parsing both get that backwards, and the fixture carries the row in both orientations.
- **The 24-hour TTL needs no clock and no waiting.** `isStale(state, {required DateTime now})` is a free function over injected time, so `23h59m → fresh`, `exactly 24h → stale`, `24h01m → stale`, `absent → stale` and `future-dated → stale` are all exact assertions in a test that runs in milliseconds.
- **Every bad read degrades to the same default and throws nothing.** Absent, non-numeric, negative-epoch, and a prefs backend that throws `PlatformException` all load as `UpdateCacheState.neverChecked()`. The cost of degrading is one extra feed check; the cost of throwing would be taking the badge and the Updates screen down with it (D-07 / D-22: a failed background check must be invisible).
- **Both formatters hit the real asset magnitudes.** `formatSize(69630935) == '66 MB'` and `formatSize(5177240) == '4.9 MB'` — the actual APK and setup-exe byte counts captured in 12-02's feed fixture, which is the whole point of the D-08 promise that the user sees a truthful size before agreeing to a ~70 MB download.
- **No dependency was added.** `pubspec.yaml` and `pubspec.lock` are untouched; `shared_preferences` was already in the tree and nothing else was needed. `grep -c "intl\|timeago\|filesize" lib/update/update_format.dart` returns 0.

## Task Commits

Each task was committed atomically:

1. **Task 1: version.dart pinned to the shared truth table** — `fdc01c0` (feat)
2. **Task 2: update_cache.dart — the 24h check cache** — `2807281` (feat)
3. **Task 3: update_format.dart — the two copy formatters** — `58f4aa0` (feat)

## Files Created

| File | Purpose |
|------|---------|
| `app/remote_control/lib/update/version.dart` | `SemVer` (tryParse / compareTo / ==), `isNewer`, `normalize`, `kSemVerPattern` — pure, no I/O |
| `app/remote_control/lib/update/update_cache.dart` | `UpdateCacheState`, `UpdateCacheStore` (load / save), `isStale`, `kUpdateCheckTtl`, the two `update.` keys, `updateCacheStoreProvider` |
| `app/remote_control/lib/update/update_format.dart` | `formatAgo`, `formatSize`, eight `{ago}` copy consts, the ` MB` suffix, `kBytesPerMb`, `kSizeDecimalCutoffMb` |
| `app/remote_control/test/update/version_test.dart` | 15 tests — fixture iteration + direct cases for parse rejection, overflow, `normalize` |
| `app/remote_control/test/update/update_cache_test.dart` | 14 tests — every TTL boundary, four degradation paths, round-trip, key namespacing |
| `app/remote_control/test/update/update_format_test.dart` | 15 tests — both plural boundaries, all four `{ago}` branches, the 10 MB switch, the real asset sizes |

## Key Implementation Notes

**`updateCacheStoreProvider` was added beyond the plan's literal API list.** Every store in this codebase (`browserSegmentStoreProvider`, `hapticsStoreProvider`, `sensitivityStoreProvider`) ships with an overridable `Provider`, and the plan's `read_first` explicitly pointed at `sensitivity.dart` "for the naming and **provider-override** conventions". Omitting it would have forced 12-08 to add it, which is a worse place for it. No `Notifier` was added — that belongs to the screen plan.

**The `PrefsKv` seam is string-only**, so the timestamp is stored as decimal epoch milliseconds in a string. That is not a workaround, it is what makes the corrupt-read path trivially exercisable: `values['update.lastCheckAt'] = 'not-a-number'` is a one-line test for the degradation rule. The seam also has no `delete`, so an absent version is written as the empty string and read back as `null`, and both spellings mean "unknown".

**`normalize` is one line over `SemVer.toString()`** because `SemVer` gained `==`, `hashCode` and `toString`. Those three were not in the plan's shape but make the fixture test able to compare parsed instances directly (`expect(SemVer.tryParse('v1.4.0'), const SemVer(1, 4, 0))`) instead of destructuring three fields per assertion.

**The typography rule is recorded but unexercised.** Neither formatter emits an ellipsis or an arrow — those live in strings the screen assembles (`Checking…`, `{installed} → {latest} · {size}`). The rule is documented at the top of `update_format.dart` and there is a guard test asserting no output ever contains `...` or `->`, so the day a formatter grows one, it grows the right character.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Two acceptance criteria were unsatisfiable as first written, because the plan's own doc-comment instruction contradicted its grep**

- **Found during:** Task 2 verification, then anticipated in Task 3
- **Issue:** Task 2 asks for a doc comment recording that "this data is NON-SECRET and therefore lives in `shared_preferences` and never in secure storage", following `sensitivity.dart`, whose comment names the package literally ("never `flutter_secure_storage`"). It then asserts `grep -c 'flutter_secure_storage' lib/update/update_cache.dart` returns 0. Writing the house-style comment made the grep return 1. Task 3 had the identical shape: it asks to document that no date- or byte-formatting package is used, then greps for `intl\|timeago\|filesize` expecting 0.
- **Fix:** Stated both rules without naming the forbidden packages — "NEVER in secure storage (keystore ops are slow and can throw after OS updates; only the auth token is a secret)", which is verbatim the `browser_segment.dart:36-38` phrasing and therefore still house style, and "no date-formatting or byte-formatting package" in `update_format.dart`. Both greps now return 0, and the criterion recovers its intent: it is a signal about *imports*, not about prose.
- **Files modified:** `app/remote_control/lib/update/update_cache.dart`, `app/remote_control/lib/update/update_format.dart`
- **Commits:** `2807281`, `58f4aa0`

### Deliberate scope additions (Rule 2 — missing critical detail)

- **A future-dated cache entry is stale.** The plan defines `isStale` as "no last check, or `now` minus the last check is at least 24 hours". Taken literally, a stored timestamp in the future makes `elapsed` negative, which is neither of those — so the cache would read fresh forever and the app would silently stop checking for updates. A timezone change or an NTP correction is enough to cause it. `isStale` now also returns true for a negative elapsed, and a test pins it.
- **A negative epoch loads as corrupt.** `-1000` parses fine as an int but means 1969; treating it as a genuine very-old check would be honouring a value the app cannot have written. It degrades to never-checked.
- **`formatSize` clamps a negative byte count to zero.** Asset sizes arrive from the release feed and are untrusted; `-1 MB` in user copy would be a defect surfacing as visible nonsense.
- **`formatAgo` renders a negative elapsed as `just now`** rather than `-3 hours ago`, for the same clock-correction reason. The cache independently treats such an entry as stale, so the line is transient by construction.
- **`SemVer` gained `==` / `hashCode` / `toString`**, and `kSemVerPattern` is exported rather than private, so a later plan can reuse the accepted-input rule without restating the regex.

## Threat Flags

None. This plan adds no endpoint, no auth path, no file access and no schema at a trust boundary — three pure/prefs-only modules with no network and no plugin channel. The two `mitigate` dispositions in the plan's register are discharged as intended: **T-12-18** by the integer-tuple compare plus the null-in-means-false rule, both asserted against the shared fixture in both directions; **T-12-20** by storing only a timestamp and a public version string, which is also the reason `shared_preferences` rather than secure storage is correct here. **T-12-19** (a tampered cache) is `accept` by disposition and remains so — the one hardening added, treating a future timestamp as stale, was motivated by clock correction rather than tampering, and incidentally removes the only interesting thing tampering could achieve.

## Known Stubs

None. All three modules are complete for their purpose. They are not yet wired to any screen or to the feed parser — that is wave ordering (12-08 onward consumes them), stated in the plan's own objective, not an unfinished stub.

## Verification

| Check | Result |
|-------|--------|
| `cd app/remote_control && flutter test test/update/` | 45 passed, 0 failed |
| `flutter test test/update/version_test.dart` | 15 passed |
| `flutter test test/update/update_cache_test.dart` | 14 passed (≥5 required) |
| `flutter test test/update/update_format_test.dart` | 15 passed (≥10 required) |
| `flutter analyze lib/update test/update` | No issues found |
| `git diff app/remote_control/pubspec.yaml` | empty — no dependency added |
| `git diff app/remote_control/pubspec.lock` | empty |
| `grep -c 'version-compare' test/update/version_test.dart` | 3 (≥1 required) |
| `grep -c 'flutter_secure_storage' lib/update/update_cache.dart` | 0 |
| `grep -c "intl\|timeago\|filesize" lib/update/update_format.dart` | 0 |
| `SemVer.tryParse('1.10.0')!.compareTo(SemVer.tryParse('1.9.0')!) > 0` | true |
| `isNewer('1.4.0-rc1', '1.4.0')` / `isNewer('latest', '1.4.0')` | false / false |
| `isNewer('999999999999999999999.0.0', '1.4.0')` | false, throws nothing |
| `formatSize(69630935)` / `formatSize(5177240)` | `66 MB` / `4.9 MB` |
| `formatAgo(1 min)` / `formatAgo(2 min)` | `1 minute ago` / `2 minutes ago` |
| `isStale` reads no clock | confirmed — `now` is a required parameter, no `DateTime.now()` in the file |
| Post-commit deletion check, all three commits | no deletions |

## For Future Phases

- **12-08 (Updates screen / controller)** consumes all three modules. Read the cache via `updateCacheStoreProvider`, call `isStale(state, now: DateTime.now())` at the launch-check decision point — that is the ONLY place `DateTime.now()` belongs — and call `save` **only after a successful check**, never after a failure, or the `Last checked` line blanks and D-22's "silent background failure" is broken.
- **The badge (UI-SPEC Component 4)** has everything it needs offline: `lastSeenVersion` from the cache plus the installed version from the package, compared with `isNewer`. Because `isNewer` returns false on any unknown, the badge automatically satisfies "never lights on `unknownVersion`" without a second guard.
- **Asset sizes are not cached.** If a future plan needs `{size}` offline, add a third `update.` key rather than assuming one is there — the omission is deliberate and documented at the top of `update_cache.dart`.
- **The fixture is the authority, in both languages.** If a version-compare case ever needs to change, change `protocol/fixtures/update/10-version-compare.json` and let both test suites fail — never patch one comparator to match the other.
- **`normalize` is the only version formatter.** The row copy renders installed and latest through it; nothing may zero-pad, re-add a `v`, or reformat (UI-SPEC Copywriting Contract).
- **Do not add a `Notifier` to `update_cache.dart` speculatively.** The screen plan owns the state shape; the store deliberately stops at load/save.

## Self-Check: PASSED

All 6 created files verified present on disk. All three task commits (`fdc01c0`, `2807281`, `58f4aa0`) verified present in git history. No file deleted across the plan's full commit range.
