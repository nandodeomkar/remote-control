---
phase: 12-in-app-updates
plan: 04
subsystem: server-core
tags: [codec, executor-trait, security, fixtures, semver, structural-guard]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 02
    provides: the protoVersion 1.8 `update.*` wire contract in SPEC §7, the twelve fixtures under `protocol/fixtures/update/`, the closed D-10 stage and D-11 error vocabularies, and the D-14 no-locator-authority rule
  - phase: 01-protocol-contract
    provides: the `{t, seq?, p}` envelope, the D-05 ignore-unknown / missing-required strictness rules, the canonical-form rule that `encode_msg` always emits `p`, and the golden-fixture harness
  - phase: 11-browser-bookmarks
    provides: the `bm.*` payload/trait/state-type shapes copied verbatim as the structural template, and `tests/extension_guard.rs` as the source-text assertion style
provides:
  - the four `update.*` Rust codecs, registered at all three points and pinned to the nine shared wire fixtures
  - `UpdateExecutor` with the narrowest possible apply signature — `fn apply(&self, target: &str)`
  - the plain-data update state types `UpdateInfo`, `LastUpdate`, `UpdateProgress`, and `ExtInfo` (the third relay watch payload)
  - `MockUpdate` — a recording double for the SC6 behavioural assertion in 12-13
  - `server_core::version` — the pure cross-language version comparator agreeing with the shared 15-case truth table
  - `tests/update_guard.rs` — the SC6 structural half, mutation-verified
affects: [12-11, 12-12, 12-13]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A security rule enforced by a source-text guard test over struct and trait bodies, with doc comments deliberately excluded from the scan so the rule can be DOCUMENTED without self-invalidating the test"
    - "Mixed-kind fixture directory handled by a `(family, filename)` skip list rather than a bare filename list, so a future `text/10-*.json` cannot be silently shadowed"
    - "A wire-count assertion on a hard-registered fixture family (`exercised == 9`), so mis-skipping a wire fixture turns the suite red instead of quietly shrinking coverage"
    - "`Default` as a never-sent sentinel: `UpdateProgress::default()` yields an EMPTY stage, a shape the closed D-10 vocabulary cannot express, because a watch channel needs an initial value and the protocol has no idle stage"

key-files:
  created:
    - server/server-core/src/version.rs
    - server/server-core/tests/update_guard.rs
  modified:
    - server/server-core/src/codec/json.rs
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/executors/mock.rs
    - server/server-core/src/lib.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/tests/fixtures.rs

key-decisions:
  - "The router's `match decoded.msg` is exhaustive, so four `Msg` variants could not be added without touching `dispatch/router.rs` — a file this plan does not own. `UpdateStatus`/`UpdateProgress` joined the permanent S→C-only ignore chain (exactly where 12-13 wants them); `UpdateCheck`/`UpdateApply` got a documented placeholder arm returning no reply, because there is no `Executors.update` field to route to until 12-12"
  - "`SPECIAL_CASE_FIXTURES` is keyed by `(family, filename)`, not by filename alone — the existing hardcoded `05-auth-proof.json` check generalised rather than a name list, so `update/10-12` are excluded without shadowing any future family's `10-*.json` wire fixture"
  - "`run_json_family` now RETURNS the number of fixtures it exercised, and `codec_fixtures_update` asserts it equals 9. Without the count, moving a wire fixture into the skip list by mistake would pass silently — the exact zero-coverage-zero-failures failure the hard-registration rule exists to prevent"
  - "`parse_semver` checks ASCII digits explicitly before `u64::from_str` rather than relying on the parser alone: `\"+4\".parse::<u64>()` is `Ok(4)`, so a bare `from_str` would accept `1.+4.0` as `1.4.0`. A release tag never carries a sign"
  - "`VersionOrder::as_str()` exists so the fixture loader compares against the truth table's literal `newer`/`older`/`same`/`unknown` strings instead of maintaining a second mapping in the test"
  - "`LastUpdate` deliberately does NOT derive `Default`, unlike its three siblings: there is no meaningful empty previous-attempt — that state is `UpdateInfo::last_update == None`, and a `Default` would invite a `{target: \"\", ok: false}` marker that reports a failure that never happened"
  - "`MockUpdate` is a standalone struct rather than another trait impl on `MockExecutors`: the update executor is not in the `Executors` bundle yet, and tests need to SET the reported info per case, which the shared `CallLog` cannot express"

patterns-established:
  - "Guard tests panic when a guarded block is NOT FOUND, rather than scanning nothing — a renamed type must turn the suite red, since silently guarding an empty string is how a rule lapses unnoticed"
  - "Executor mocks mirror non-idempotent read semantics (`info()` TAKES the marker) rather than simplifying them away, so the mock cannot make a test pass that the real contract would fail"

requirements-completed: [D-09, D-10, D-11, D-12, D-14, SC6]

# Metrics
duration: 35min
completed: 2026-08-01
---

# Phase 12 Plan 04: server-core update codecs, the UpdateExecutor trait, and the SC6 guard Summary

**D-14 stopped being a rule people remember and became a property of the type system: `UpdateApplyPayload` has exactly one field, `UpdateExecutor::apply` takes exactly one `&str`, and a mutation-verified guard test fails the build the moment either grows a `url`, `asset`, `sha256`, `digest`, `hash`, `file` or `path`.**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3 of 3
- **Files modified:** 8 (2 created, 6 modified)
- **Test count:** 207 → 223 workspace tests passing (16 added)

## Accomplishments

- **Four messages round-trip against the shared fixtures.** `UpdateCheckPayload` (empty, so `p` still canonicalises to `{}`), `UpdateStatusPayload` with the nested D-12 `lastUpdate` object, the one-field `UpdateApplyPayload`, and `UpdateProgressPayload`. All four registered at the three points that must agree — `enum Msg`, `decode_text`, `encode_msg` — plus four `round_trip_update_*` tests that pin the skip-when-absent optionals (`extVersion`, `lastUpdate`, `pct`, `version`, `error` all stay ABSENT rather than emitting null) and both missing-required-field hard errors by name.
- **The trait is the narrowest point the wire can reach, and it says so.** `fn apply(&self, target: &str)` — one string, no second parameter of any type. Its doc comment states D-14 verbatim, including the consequence (a widened signature converts a paired phone into arbitrary code execution on the PC) and the enforcement (`tests/update_guard.rs`). `fn info(&self) -> UpdateInfo` documents that it is a cheap no-I/O read that TAKES the pending marker, so a `lastUpdate` is reported on exactly one `update.status` and never again (D-12) — a `&self` method that is deliberately not idempotent.
- **SC6's structural half is real, and was proven to bite.** The mutation check ran: adding `pub url: String` to `UpdateApplyPayload` turned BOTH guards red — the locator scan named `"url"` and the field-count assertion reported `declares 2 fields, expected exactly 1`. The field was removed and both pass again. The guard excludes doc comments from its scan on purpose: the update types deliberately discuss urls and hashes so a future reader understands the rule, and a naive whole-file scan would have made the clearest documentation the reddest test.
- **The version comparator agrees with the phone before the phone exists.** All fifteen truth-table cases pass, including the lexical trap in both directions (`1.10.0` vs `1.9.0`), `v`-stripping on either or both sides, and all five unknown cases. `unknown` on either side is `unknown`, never `newer` — the property that stops a malformed tag from triggering an update offer.
- **Nothing rippled.** `cargo build -p server-windows` still succeeds: no field was added to `Executors` or `ServerDeps`, so `server-windows/src/main.rs` and every test harness are untouched. That ripple is 12-12's, exactly as the plan drew the boundary.

## Task Commits

Each task was committed atomically:

1. **Task 1: The four `update.*` payload types and their `Msg` variants** — `f80cfeb` (feat)
2. **Task 2: The `UpdateExecutor` trait, its state types, and a recording mock** — `62d5daf` (feat)
3. **Task 3: Register the fixture family and land the SC6 structural guard** — `8b90e41` (test)

## Files Created

| File | Purpose |
|------|---------|
| `server/server-core/src/version.rs` | `parse_semver`, `compare_versions`, `enum VersionOrder` — pure, `core`-only, zero Windows deps; 5 unit tests beside the fixture-driven one |
| `server/server-core/tests/update_guard.rs` | The SC6 structural guard: no locator-named field or parameter in any update payload or the trait, and `UpdateApplyPayload` has exactly one field named `target` |

## Files Modified

| File | Change |
|------|--------|
| `server/server-core/src/codec/json.rs` | Five new structs (four payloads + nested `LastUpdatePayload`), four `Msg` variants, four decode arms, four encode arms, four round-trip tests |
| `server/server-core/src/executors/mod.rs` | `UpdateProgress`, `LastUpdate`, `UpdateInfo`, `ExtInfo`, and the `UpdateExecutor` trait |
| `server/server-core/src/executors/mock.rs` | `MockUpdate` — settable info, recorded applies, marker-taken-once — plus 3 tests |
| `server/server-core/src/lib.rs` | `pub mod version;` |
| `server/server-core/src/dispatch/router.rs` | Exhaustive-match placeholder arms (see Deviations) |
| `server/server-core/tests/fixtures.rs` | `SPECIAL_CASE_FIXTURES`, `run_json_family` returns a count, `codec_fixtures_update`, `version_compare_matches_fixture` |

## Key Implementation Notes

**The `Executors` bundle was NOT touched, and that was the point.** The trait and its state types simply come into existence so that 12-11's `WinUpdate` has something to implement and 12-13 has something to route to. `ExtInfo` in particular is defined a wave before anything produces into it: `run_ext` will publish the captured `ext.hello` `extVersion` there in 12-12, and `WinUpdate::info` reads it to fill `update.status`'s `extConnected`/`extVersion`.

**`UpdateProgress::default()` is an empty `stage`, which is a sentinel the wire never carries.** The D-10 vocabulary has seven values and none of them mean "idle", but a watch channel needs an initial value. Rather than invent an eighth stage that the phone would have to learn to ignore, the initial value is a shape the protocol cannot express, and the session push arm skips it. Anything reading the type must treat `stage.is_empty()` as "nothing has happened yet" — this is documented on the type.

**The nine wire fixtures are hard-registered AND counted.** `codec_fixtures_update` asserts `run_json_family("update") == 9`. The mixed-kind directory made a count necessary: files 10-12 have no `{wire, expect}` envelope and must be skipped, and a skip list without a count is a coverage hole waiting to happen.

**No dependency was installed.** This plan is `serde`, `serde_json` and `core` only — all already in the tree. The phase's two new dependencies (`ureq`, `crypto`) belong to 12-06 and 12-10.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] `dispatch/router.rs` failed to compile: the `match decoded.msg` is exhaustive**

- **Found during:** Task 1
- **Issue:** Adding four variants to `enum Msg` broke `route()` with `E0004: non-exhaustive patterns`. The plan's `files_modified` list does not include `dispatch/router.rs` (12-13 owns it), but `server-core` could not compile — and therefore no acceptance criterion in this plan could be checked — until the four arms existed.
- **Fix:** Split by direction, matching what 12-13's Task 1 specifies so the placeholder is a subset of the final state rather than something to unwind:
  - `Msg::UpdateStatus(_)` and `Msg::UpdateProgress(_)` joined the existing S→C-only silent-ignore chain. This is **permanent and final** — 12-13 asks for exactly this, so those two lines will not be revisited.
  - `Msg::UpdateCheck(_) | Msg::UpdateApply(_) => Vec::new()` is a **documented placeholder**. There is no `Executors.update` field to call yet (12-12 adds it), so there is nothing to route to. Returning nothing was chosen over `err{unknownType}` because the type IS known — an `unknownType` reply would be a lie the phone might cache as "server too old to update itself" (SPEC §10). A twelve-line comment names 12-12 and 12-13, states exactly what replaces the arm, and records that the family is inert until the 1.8 flip.
- **Files modified:** `server/server-core/src/dispatch/router.rs`
- **Commit:** `f80cfeb`

### Deliberate scope additions (Rule 2 — missing critical detail)

- **`run_json_family` returns a count, and `codec_fixtures_update` pins it at 9.** The plan asked for the family to be registered and for the special-case files to be excluded. A skip list with no count assertion means that moving a wire fixture into the skip list — or a future family gaining a tenth wire fixture that nobody registers — passes silently. The count turns both into a red test.
- **`SPECIAL_CASE_FIXTURES` is keyed by `(family, filename)` rather than filename.** The plan permitted "move the three special-case files behind the runner's existing skip convention". That convention was a bare `name == "05-auth-proof.json"` check; extending it with bare names would have made any future `text/10-*.json` or `tabs/11-*.json` silently skipped. Generalising to a `(family, filename)` pair list costs one tuple per entry and removes the trap.
- **`update_guard.rs` panics when a guarded block is not found.** Not requested. A guard that scans a missing type finds no forbidden strings and passes — so a rename would disarm the rule while leaving a green test as evidence that it holds. The panic message says explicitly: update `GUARDED_BLOCKS`, do not delete the guard.
- **`parse_semver`'s explicit ASCII-digit check.** `u64::from_str` accepts a leading `+`, so `1.+4.0` would have parsed as `1.4.0` under a bare `.parse()`. Not in the fixture's fifteen cases, but a comparator that accepts signed components is one that accepts input the tag format never produces.
- **Three extra `MockUpdate` tests and five extra `version.rs` unit tests.** The fixture table is the cross-language contract; these cover the Rust-side edges it does not reach (marker-taken-once, apply recording order, `1.4.0.1`, `1..0`, whitespace, the `+` case).

## Threat Flags

None. This plan added no endpoint, no auth path, no file access and no network call — `version.rs` is pure arithmetic over strings and the trait has no implementation in this crate. The plan's three `mitigate` dispositions are discharged as intended:

| Threat | Disposition | How it was discharged here |
|--------|-------------|----------------------------|
| T-12-01 (EoP, wire-supplied locator) | mitigate | `UpdateApplyPayload` has exactly one field; `UpdateExecutor::apply` takes exactly one `&str`; `tests/update_guard.rs` fails the build on either growing a locator — mutation-verified |
| T-12-10 (Tampering, `target` content) | mitigate | The codec deliberately does NOT validate `target`, per the file-level enum-string rule; the strict `^\d+\.\d+\.\d+$` gate is 12-11's first refusal. `compare_versions` returning `Unknown` for anything that is not three integers is the ordering half of that gate, landed here |
| T-12-06 (Info disclosure, `error` text) | mitigate | Typed as plain `String` with a doc comment naming the closed D-11 vocabulary and stating "never free text, never a path, never a URL, never an HTTP status, never an exception name"; the only producer is 12-11 |

## Known Stubs

**1. `Msg::UpdateCheck` / `Msg::UpdateApply` route nowhere (`dispatch/router.rs`).**
Both decode correctly and produce no reply. This is a wave-ordering fact, not unfinished work: there is no `Executors.update` field to call until 12-12, and 12-13 owns the real arms. The plan's objective states the boundary explicitly ("This plan deliberately does NOT add a field to `Executors` or `ServerDeps`"). The arm carries a comment naming both successor plans and what replaces it. It cannot mislead a user in the meantime — SPEC.md still declares protoVersion 1.7, so no shipped phone sends these types.

Nothing else. `server_core::version`, the codecs, the trait, the mock and both guard tests are complete for their purpose.

## Verification

| Check | Result |
|-------|--------|
| `cargo test -p server-core` | 122 + 16 + 4 + 11 + 25 + 2 passed, 0 failed |
| `cargo test --workspace` | 223 passed, 0 failed, 2 ignored |
| `cargo build -p server-windows` | Finished, 0 errors — no bundle field rippled out |
| `cargo test -p server-core round_trip_update` | 4 tests, exit 0 |
| `cargo test -p server-core codec_fixtures_update` | exit 0; asserts exactly 9 wire fixtures exercised |
| `cargo test -p server-core version_compare_matches_fixture` | exit 0; all 15 truth-table cases |
| `cargo test -p server-core --test update_guard` | 2 tests, exit 0 |
| **Mutation check** — add `pub url: String` to `UpdateApplyPayload` | **BOTH guards FAILED as designed:** `D-14 VIOLATION: ... contains a field or parameter naming "url"` and `UpdateApplyPayload declares 2 fields, expected exactly 1`. Field removed; both green again |
| `grep -c 'UpdateApplyPayload' src/codec/json.rs` | 4 (≥3 required) |
| `grep -c '"update\.' src/codec/json.rs` | 11 (≥8 required) |
| `grep -c 'trait UpdateExecutor' src/executors/mod.rs` | 1 |
| `grep -c 'struct ExtInfo' src/executors/mod.rs` | 1 |
| `UpdateExecutor::apply` signature | `fn apply(&self, target: &str);` — no additional parameter |
| `grep -c 'run_json_family("update")' tests/fixtures.rs` | 1 |
| `grep -c 'pub mod version;' src/lib.rs` | 1 |
| `grep -v '^\s*//' src/version.rs \| grep -Ec 'windows\|winapi'` | 0 — zero-Windows-deps invariant holds |
| Post-commit deletion check on all three commits | no deletions |

## For Future Phases

- **12-05 (Dart codec)** registers the same nine wire fixtures on the Dart side and needs its own loader for `10-version-compare.json`. The Dart comparator must produce the same four strings; `VersionOrder::as_str()` is the Rust spelling to match. The negative fixtures fail on `target` and `serverVersion` respectively — the Rust side asserts the exact missing field name, and doing the same in Dart catches a decoder failing for the wrong reason.
- **12-11 (`WinUpdate`)** implements `UpdateExecutor`. `info()` must TAKE the marker, not copy it (`MockUpdate` shows the shape). `apply()` gets a bare version string — resolve the URL and sha256 from your own compiled-in repo constant, and gate `target` on `^\d+\.\d+\.\d+$` before any use. `compare_versions` is already there for the `downgrade` check; `Unknown` must refuse, never offer.
- **12-12** adds the `update` field to `Executors`/`ServerDeps` and wires `ExtInfo` into the ext relay. That is the ripple this plan deliberately avoided — expect `server-windows/src/main.rs` and every harness that constructs an `Executors` to need a line.
- **12-13** replaces the two placeholder router arms. `Msg::UpdateStatus`/`Msg::UpdateProgress` are ALREADY in the S→C ignore chain where 12-13 wants them — only `UpdateCheck`/`UpdateApply` need real bodies, plus the `is_executor_bound` amendment and its doc-comment update.
- **Do not add a field to `UpdateApplyPayload` or a parameter to `UpdateExecutor::apply`.** If the update flow needs more information, the SERVER resolves it. `tests/update_guard.rs` will stop you, and the failure message explains why before you reach for the delete key.
- **`SPECIAL_CASE_FIXTURES` is the extension point for future mixed-kind families** — add a `(family, filename)` pair; do not switch it back to bare filenames.

## Self-Check: PASSED

All 8 files verified present on disk (2 created, 6 modified). All three task commits verified in git history: `f80cfeb`, `62d5daf`, `8b90e41`.
