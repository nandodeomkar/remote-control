---
phase: 12-in-app-updates
plan: 05
subsystem: protocol
tags: [wire-protocol, dart, codec, fixtures, forward-compatibility, security]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 02
    provides: the protoVersion 1.8 `update.*` registry rows, the closed stage/error vocabularies, the D-14 no-locator-authority rule, and the twelve shared fixtures under `protocol/fixtures/update/`
  - phase: 01-protocol-contract
    provides: the `{t, seq?, p}` envelope, the `_req`/`_opt` strictness helpers, the `UnknownMsg` fallthrough, and the golden-fixture harness in `fixture_test.dart`
provides:
  - Dart codecs for update.check / update.status / update.apply / update.progress in `remote_protocol`
  - the `LastUpdate` nested value type with value-equal `==`/`hashCode` for provider state comparison
  - the Dart half of the shared-fixture pin — nine golden files now drive BOTH codecs
  - `specialCaseFixtures`, a harness-owned exclusion list for mixed-kind fixture directories
  - named tests for the two SC8 directions (D-13 backward refusal, forward unknown-`t` survival)
affects: [12-09, 12-11, 12-15, 12-13]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Harness-owned special-case list: `specialCaseFixtures` keyed by family, so registration lines all stay `runJsonFamily('family')` and the harness itself knows which files it cannot parse"
    - "A fixture-count assertion beside a fixture exclusion, so narrowing coverage fails a test instead of passing quietly"
    - "Security rule carried as a class doc comment that states what may never be added, not just what exists (UpdateApplyMsg / D-14)"

key-files:
  created:
    - app/packages/remote_protocol/test/update_forward_compat_test.dart
  modified:
    - app/packages/remote_protocol/lib/src/json_codec.dart
    - app/packages/remote_protocol/test/fixture_test.dart

key-decisions:
  - "The three special-case fixtures are excluded by a harness-level `specialCaseFixtures` map rather than a per-call skip argument — the registration line stays exactly `runJsonFamily('update')`, and the pre-existing hardcoded `05-auth-proof.json` skip was absorbed into the same map instead of a second mechanism living beside it"
  - "`LastUpdate` serialises via `toPayload()` (the plan's wording) rather than the `toJson()` used by the file's three older nested value classes — recorded here because it is a second name for the same role in one file"
  - "`app/packages/remote_protocol/lib/src/version.dart` was deliberately NOT touched; it still advertises `'1.1'`. SC8's 'a 1.8 phone' means the phone KNOWS the update.* types, not that it advertises 1.8"
  - "A fourth forward-compat group asserts the converse of SC8 — that all four 1.8 types do NOT fall through to UnknownMsg — because a missing switch arm would leave every other test in the file passing"

requirements-completed: [D-09, D-10, D-11, D-12, D-13, D-14, SC8]

# Metrics
duration: 20min
completed: 2026-08-01
---

# Phase 12 Plan 05: Dart update.* Codecs Summary

**The phone can now read and write all four protoVersion 1.8 `update.*` messages, pinned to the exact same nine golden files the Rust codec consumes — and both SC8 directions (a 1.7 server's refusal, a future server's unknown type) are proven by named tests rather than assumed from the fallthrough's existence.**

## Performance

- **Duration:** ~20 min
- **Tasks:** 2 of 2
- **Files modified:** 3 (1 created, 2 modified)

## Accomplishments

- **Four message classes plus one nested value type, in the file's existing idiom.** `UpdateCheckMsg` (empty payload whose canonical re-encode still emits `p` as `{}`), `UpdateStatusMsg` (two required fields, two absent-not-null optionals, one of them the nested `lastUpdate`), `UpdateApplyMsg` (exactly one field), `UpdateProgressMsg` (`stage` plus three optionals), and `LastUpdate` with value-equal `==`/`hashCode` so a Riverpod state comparison in 12-11 does not see a fresh object as a change.
- **D-14 is carried in the type, not only in the doc.** `UpdateApplyMsg` has one field. The class doc states what may never be added and why — a wire-supplied url, asset name, filename or hash would turn a paired phone into arbitrary code execution on the PC — so the next person to consider a "convenient" field reads the reason at the point of temptation. The class body contains no locator-shaped identifier at all.
- **Nine fixtures, one copy.** `runJsonFamily('update')` is hard-registered, so `02-update-status-full.json` proves the unknown `future` key nested inside `lastUpdate` is dropped on canonical re-encode, `03` proves both optionals stay ABSENT rather than becoming null, `07` proves all three progress optionals do the same, and `08`/`09` prove a missing required field is a hard decode error. No Dart-side fixture copy exists (D-09 / SPEC §14).
- **The mixed-kind directory did not silently poison the harness.** `runJsonFamily` globs the whole family directory, so registering `update/` unfiltered would have fed `10-version-compare.json` and the two `releases/latest` captures — files with no `t`/`p` envelope — into the wire harness and failed. The exclusion lives in the harness as `specialCaseFixtures`, and a count assertion pins the wire-fixture total at nine so a future typo in that list cannot quietly shrink coverage.
- **SC8 is a test, not a claim.** Seven tests across three groups: the `err{code: unknownType}` a 1.7 server sends decodes with the code intact (the value 12-15 maps to the `serverTooOld` row state) and round-trips; an unknown newer `t` decodes to `UnknownMsg` with `t` preserved and re-encodes with an EMPTY `p` — the codec never echoes an unparsed body back at the server; and `update.rollback` confirms `update.` is a prefix, not a wildcard.

## Task Commits

Each task was committed atomically:

1. **Task 1: The four Dart update.* message classes** — `10b0124` (feat)
2. **Task 2: Register the fixture family and prove the SC8 path** — `d8ccbbb` (test)

## Files Created

| File | Purpose |
|------|---------|
| `app/packages/remote_protocol/test/update_forward_compat_test.dart` | The two SC8 directions plus the converse check that the four 1.8 types are known to this build |

## Files Modified

| File | Change |
|------|--------|
| `app/packages/remote_protocol/lib/src/json_codec.dart` | +239 lines: `UpdateCheckMsg`, `LastUpdate`, `UpdateStatusMsg`, `UpdateApplyMsg`, `UpdateProgressMsg`, and four `decodeText` switch arms |
| `app/packages/remote_protocol/test/fixture_test.dart` | `specialCaseFixtures` map + `wireFixtureFiles()` helper; `runJsonFamily` now filters through them; `group('update fixtures')` with the nine-fixture count guard |

## Key Implementation Notes

**`version.dart` is untouched, on purpose.** It still declares `protoVersion = '1.1'`. SC8's "a 1.8 phone" means the phone knows the `update.*` types — changing what the client advertises in `hello` is a handshake-path behaviour change with its own test surface and is not in this phase. `git diff --stat` against the wave base confirms only the three files above changed. The forward-compat file's header comment records this reading so the next reader does not "fix" it as an oversight.

**`stage` and `error` are plain Strings.** The closed D-10 and D-11 vocabularies are rendered by the UI copy map in 12-15, not enforced by the codec — the same value-lenient treatment every other enum-valued field in this file gets, and the same treatment the Rust side gives them. That closedness is itself the T-12-06 mitigation: because the vocabulary cannot carry a path, URL, HTTP status or exception name, a server that violated D-11 still could not paint one onto the phone's screen.

**The `05-auth-proof.json` skip moved rather than gaining a sibling.** It was a hardcoded `if (name == '05-auth-proof.json') continue;` inside `runJsonFamily`, applied to every family. It now lives under the `handshake` key of `specialCaseFixtures` — same effect (no other family has that filename), one mechanism instead of two.

**No dependency was installed.** `dart pub get` ran to populate this fresh worktree's `.dart_tool` from the existing `pubspec.yaml`; no package was added. The phase's `crypto` dependency belongs to 12-10.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Dart dependencies were unresolved in the worktree**

- **Found during:** Task 1 verification
- **Issue:** `dart analyze` reported 88 errors — every `package:` import unresolved — because a freshly created git worktree has no `.dart_tool/package_config.json` (it is gitignored). Not a code defect; the environment was simply not bootstrapped.
- **Fix:** Ran `dart pub get` in `app/packages/remote_protocol`. It resolved the existing pinned dependencies only; nothing was added to `pubspec.yaml`, and the resolution produced no tracked-file change.
- **Files modified:** none tracked
- **Commit:** n/a (environment step)

### Deliberate scope additions (Rule 2 — missing critical functionality)

- **`wireFixtureFiles()` + the nine-fixture count assertion.** The plan asked for the three special-case files to be excluded and for the mechanism to be recorded. An exclusion list creates its own failure mode: a typo in a filename, or a future special case added carelessly, would remove a wire fixture from the harness while `all scenarios` kept passing. The count assertion turns that into a failing test. This is the same class of hazard as the "unregistered family = zero coverage AND zero failures" lesson the bookmarks comment already records.
- **A fourth test group: "the four 1.8 types are known to THIS build".** The plan's three SC8 cases all exercise the `UnknownMsg` fallthrough. If a `decodeText` switch arm were missing or misspelled, all three would still pass — the missing type would simply fall through, which is exactly what those tests assert is fine. The added group asserts the converse for all four types, so the fixture registration and the switch cannot silently drift apart.
- **`update.rollback` as a fourth forward case.** Guards that `update.` is matched as a whole string, not a prefix: a future sibling type must not dispatch into an existing decoder and throw on that decoder's required fields.

### Naming note (not a deviation, recorded for consistency)

`LastUpdate` exposes `toPayload()` as the plan specifies. The three older nested value classes in the same file (`WindowInfo`, `TabInfo`, `BmNode`) use `toJson()`. Following the plan's wording introduces a second name for the same role in one file; it is called out here so a later plan renames deliberately rather than by accident.

## Threat Flags

None. This plan adds no endpoint, no auth path and no file access. The plan's threat register is discharged as written: **T-12-01** (elevation of privilege via `update.apply`) by the one-field type plus the class doc stating no field may ever be added; **T-12-06** (information disclosure via `update.progress.error`) by decoding the error as an opaque String that only the 12-15 copy map renders; **T-12-12** (denial of service via malformed `update.status`) by `_req` throwing `FormatException` at the codec boundary — verified against fixtures `08` and `09`, which assert the failure names the exact missing field; **T-12-08** (forward-compat spoofing) accepted by design and now proven by test rather than assumed.

## Known Stubs

None.

## Verification

| Check | Result |
|-------|--------|
| `cd app/packages/remote_protocol && dart test` | 22 passed, 0 failed |
| `dart test` output names an `update fixtures` group | yes — `all scenarios` + `exercises exactly nine wire fixtures` |
| `dart test test/update_forward_compat_test.dart` | 7 passed (≥3 required) |
| `dart analyze` | No issues found |
| `grep -c "'update\." lib/src/json_codec.dart` | 8 (≥8 required — four `t` getters + four switch arms) |
| `grep -c "runJsonFamily('update')" test/fixture_test.dart` | 1 |
| Decoding `{"t":"update.apply","p":{}}` | throws `FormatException: missing required field: target` |
| `UpdateStatusMsg.toPayload()` with both optionals null | exactly two keys |
| Decoding `{"t":"update.somethingFromTheFuture","p":{"x":1}}` | `UnknownMsg` with `t` preserved |
| `git diff --stat` vs wave base — `version.dart` | untouched (3 files changed, none of them `version.dart`) |
| Post-commit deletion check on both commits | no deletions |

## For Future Phases

- **12-11 (connection/provider layer)** can compare `UpdateStatusMsg`/`LastUpdate` by value — `LastUpdate` implements `==`/`hashCode`; the message classes themselves do NOT (no message class in this file does), so a provider holding a whole message must compare the fields it cares about.
- **12-15 (UI copy map)** owns the closed D-10 stage and D-11 error vocabularies. The codec passes both through as Strings; render an unrecognised value as a generic fallback rather than raw text, or T-12-06 reopens.
- **12-15** should map `ErrMsg.code == 'unknownType'` in reply to an `update.check` to the `serverTooOld` row state — the exact assertion in `update_forward_compat_test.dart`.
- **12-07** owns fixtures `10`, `11` and `12`. They are excluded from the Dart wire harness via `specialCaseFixtures['update']` and need a bespoke loader; read `response.assets` (nested under `response`).
- **12-13** flips `protocol/SPEC.md` line 3, `SERVER_PROTO_VERSION` and `protocol/fixtures/beacon/01-valid.json` to `1.8`. Whether `app/packages/remote_protocol/lib/src/version.dart` also moves off `'1.1'` is that plan's call — this plan deliberately left it alone, and nothing here depends on the advertised value.
- **Adding a wire fixture to `update/`** needs no registration change (the family globs). Adding a NON-wire fixture requires an entry in `specialCaseFixtures['update']` AND bumping the nine-fixture count assertion.

## Self-Check: PASSED

All three files verified present with the expected content; both task commits (`10b0124`, `d8ccbbb`) verified present in git history; working tree clean after each commit.
