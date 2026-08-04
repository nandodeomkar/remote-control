---
phase: 12-in-app-updates
plan: 13
subsystem: server
tags: [rust, protocol, router, dispatch, session-push, auth-gate, pause-gate, proto-version]

# Dependency graph
requires:
  - phase: 12-02
    provides: the update.* codecs, the S→C-only ignore chain, SPEC §2's 1.8 addition line
  - phase: 12-04
    provides: UpdateExecutor trait, UpdateInfo/LastUpdate/UpdateProgress, MockUpdate
  - phase: 12-12
    provides: Executors.update, ServerDeps.update, the named `update` destructure in listener.rs
provides:
  - "The four update.* router arms — update.check replies one update.status, update.apply passes only the target string"
  - "is_executor_bound amended: update.check and update.apply are both pause-bound (D-13), with the exemption rule's doc comment amended rather than contradicted"
  - "The authed-gated update.progress session push arm, with the empty-stage sentinel filtered"
  - "protoVersion 1.8 declared simultaneously in SERVER_PROTO_VERSION, SPEC.md and the beacon fixture"
  - "SC6's behavioural third (forged_apply_is_refused) and SC8 (unknown_update_type_keeps_session_alive)"
affects: [12-15, 12-16, 12-17, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A select! push arm that clears the watch's changed flag BEFORE deciding whether to publish, so a filtered sentinel value cannot re-fire the branch"
    - "A read that is deliberately NOT pause-exempt, with the exemption rule's own doc comment amended to record the counter-example and its reason"

key-files:
  created: []
  modified:
    - server/server-core/src/dispatch/router.rs
    - server/server-core/src/transport/session.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/tests/integration.rs
    - protocol/fixtures/beacon/01-valid.json
    - protocol/SPEC.md

key-decisions:
  - "update.check joins is_executor_bound even though it is a read. The SPEC §11 exemption exists because answering a list while paused is harmless — it describes the machine and offers nothing. update.check describes a machine about to be REPLACED, and the only thing the phone does with the answer is offer an install; answering it while paused would advertise an action the session has just been told it may not take. The doc comment above is_executor_bound was AMENDED to record this counter-example so a future reader cannot 'fix' it back"
  - "The empty-stage sentinel is filtered INSIDE the arm, after borrow_and_update. Filtering before the borrow would leave the changed flag set and the branch would spin; filtering after keeps the skip a true no-op"
  - "The three-file 1.8 bump landed in ONE commit (SERVER_PROTO_VERSION, SPEC.md line 3 + the §2 sentence, and BOTH pins in protocol/fixtures/beacon/01-valid.json). SPEC §2's '1.8 addition' bullet was already written by 12-02, so only the two version declarations moved"
  - "pause_drops_update was WRITTEN rather than skipped: the Task-1 router test proves the gate, but it is a unit test on route() — only a socket test proves the gate is reached through the real session path, which is the division of labour paused_input_dropped already uses"
  - "Harness gained an update_exec: Arc<MockUpdate> field alongside log, because the update slot is deliberately not the shared CallLog — the tests need to SET what info() reports per case"

patterns-established:
  - "A cross-referenced security criterion: forged_apply_is_refused states in its doc comment exactly what it proves, exactly what it does not, and names the two other tests (server-windows refusal_order, server-core --test update_guard) that carry the remaining thirds — so a future reader who finds one can find all three"

requirements-completed: [D-09, D-11, D-12, D-13, D-14, SC5, SC6, SC8]

# Metrics
duration: 22min
completed: 2026-08-04
---

# Phase 12 Plan 13: Routing the Update Family Summary

**The update family is now reachable over the wire — four router arms behind the same auth and pause gates every other family obeys, one authed-gated progress push, and protoVersion 1.8 declared in the constant, the spec and the beacon fixture in a single commit.**

Everything before this plan built capability. This plan granted access to it.

## Performance

| Metric | Value |
|--------|-------|
| Tasks | 3 |
| Commits | 3 (+1 docs) |
| Rust workspace tests | 300 passed / 0 failed / 2 ignored (was 293) |
| New tests | 7 |
| Build warnings | 0 |

## What Was Built

### Task 1 — the four router arms and the executor-binding amendment (`a4deabd`)

`router.rs`'s documented placeholder (`UpdateCheck | UpdateApply => Vec::new()`, carried since 12-02) is gone:

- **`Msg::UpdateCheck(_)`** — the `bm.list` read-with-reply shape. Calls `exec.update.info()` **once** and maps `UpdateInfo` field-for-field into a single `Msg::UpdateStatus`. The arm carries a comment recording that `info()` *takes* the pending marker, so this arm is the one and only place `lastUpdate` can appear (D-12) — calling `info()` twice anywhere on the request path would silently consume the marker.
- **`Msg::UpdateApply(p)`** — fire-and-forget. Calls `exec.update.apply(&p.target)`, returns an empty vector. Comment states D-14/T-12-01 plainly: `&p.target` is the only value that crosses, the executor resolves the asset URL and sha256 itself from a `server-windows` constant the codec cannot see.
- **`Msg::UpdateStatus(_)` / `Msg::UpdateProgress(_)`** — verified already on the permanent S→C-only ignore chain (12-02 put them there and marked them FINAL). No change needed; a new test now pins the behaviour.
- **`is_executor_bound`** — both variants added, and the function's doc comment amended to name `update.check` as the one read that is deliberately NOT exempt, with the reason.

### Task 2 — the progress push arm and the atomic 1.8 bump (`73ce5f1`)

- `session.rs` gained an `update.changed()` select arm cloned byte-for-byte from the `bm.changed` arm at `:368`: gated on `update_alive && ctx.auth_state == AuthState::Authed` (T-12-42), `borrow_and_update().clone()`, `try_send` dropping on `Full` and breaking the read loop on `Closed` (T-12-47), `update_alive = false` on `Err(_)`.
- **The empty-stage sentinel is skipped entirely** (T-12-46). The skip sits *after* `borrow_and_update`, so the changed flag is cleared and the branch cannot re-fire.
- `listener.rs` threads `ServerDeps.update` into `run_session` (12-12's `update: _update` binding lost its underscore).
- The version bump landed atomically across `SERVER_PROTO_VERSION` (`session.rs:65` → `"1.8"`), `protocol/SPEC.md` line 3 and its §2 "Current version" sentence, and **both** pins in `protocol/fixtures/beacon/01-valid.json`.

### Task 3 — the SC6 and SC8 integration tests (`6cb9599`)

Four named socket-level tests, plus a `Harness.update_exec` handle so tests can seed `info()` and read back every recorded `apply`.

## Key Decisions

**`update.check` is pause-bound despite being a read.** The SPEC §11 exemption covers `apps.list`, `clip.get`, `tabs.list` and `bm.list` because answering a list while paused is harmless. `update.check` is different in kind: it reports the version state of a machine that is about to be replaced, and its answer's only consumer is the phone's "install this" affordance. The `is_executor_bound` doc comment now carries the counter-example and its reason, so the rule is amended rather than silently contradicted.

**`pause_drops_update` was written, not skipped.** The plan permitted skipping it if the Task-1 router test already covered the session path. It does not — it is a unit test on `route()`. The socket test proves the gate is reached through the real session, and includes an unpause control so the silence is provably the gate and not a dead route.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] The plan's acceptance criterion named a test that does not exist**

- **Found during:** Task 2
- **Issue:** Three acceptance criteria cite `codec_fixtures_beacon`. `server/server-core/tests/fixtures.rs` has no beacon family — the beacon fixture is consumed by the unit test `encode_beacon_matches_valid_fixture_wire` in `server/server-core/src/transport/beacon.rs:136`, and on the Dart side by `app/remote_control/test/beacon_test.dart`.
- **Fix:** Ran the real gates instead. Both were verified green after the bump (`cargo test -p server-core encode_beacon_matches_valid_fixture_wire`, `flutter test test/beacon_test.dart` — 8 passed). The *pitfall* the criterion was guarding against is real and was honoured: the constant and both fixture pins moved in the same commit.
- **Files modified:** none (verification-only correction)
- **Commit:** `73ce5f1`

**2. [Rule 2 - Missing critical] `SERVER_PROTO_VERSION`'s doc comment had no 1.7 entry**

- **Found during:** Task 2
- **Issue:** The running changelog in the constant's doc comment stopped at 1.6 while the constant itself read `"1.7"` — the zoom-opcode bump (quick 260731-euq) was never recorded there, so appending a 1.8 line would have left a visible hole.
- **Fix:** Added the missing 1.7 line (sourced from SPEC.md:42) alongside the new 1.8 line, plus an explicit warning that the literal is embedded in the beacon payload and pinned twice in the fixture.
- **Files modified:** `server/server-core/src/transport/session.rs`
- **Commit:** `73ce5f1`

**3. [Rule 3 - Blocking] Heredoc append failed under the shell**

- **Found during:** Task 3
- **Issue:** A `cat >> file <<'EOF'` append of the test block aborted with `unexpected EOF while looking for matching '`. No file was modified.
- **Fix:** Wrote the block to the scratchpad with the Write tool and appended it with a plain `cat`. Noted here because the same failure will recur for any large Rust append containing apostrophes.
- **Files modified:** `server/server-core/tests/integration.rs`
- **Commit:** `6cb9599`

### Not deviations, recorded for the next plan

- `Msg::UpdateStatus`/`Msg::UpdateProgress` needed no ignore-chain edit — 12-02 already placed them there and marked them final. Task 1's action said "add BOTH"; they were already present.
- `Harness._update_tx` needed only the `_` prefix dropped, exactly as 12-12's carry-forward predicted.

## New Tests

| Test | Location | Proves |
|------|----------|--------|
| `update_commands_route_when_unpaused` | `router.rs` | one `update.status` from a check, zero frames from an apply, target recorded verbatim |
| `client_sent_update_pushes_ignored_without_err` | `router.rs` | a client-sent `update.status`/`update.progress` gets no reply and no err of any code |
| `update_progress_authed_gate_silence_then_single_push` | `integration.rs` | pre-auth silence, no after-auth snapshot, one push per change, sentinel skipped, branch alive after the skip |
| `forged_apply_is_refused` | `integration.rs` | SC6 behavioural third — zero replies, exact recorded argument, no other executor touched |
| `update_check_reports_marker_once` | `integration.rs` | D-12 — `lastUpdate` on the first status, absent on the second |
| `unknown_update_type_keeps_session_alive` | `integration.rs` | SC8 — `err{unknownType}` then the same session answers a known `update.check` and a ping |
| `pause_drops_update` | `integration.rs` | T-12-45 at socket level, with an unpause control |

Also extended: `paused_drops_every_executor_bound_family_silently` now carries both update types and asserts `update.applies()` stayed empty.

## SC6's three thirds

`forged_apply_is_refused`'s doc comment names all three so a future reader who finds one finds the others:

| Third | Test | Crate |
|-------|------|-------|
| Behavioural — the wire carries no locator | `forged_apply_is_refused` | `server-core --test integration` |
| Refusal — the executor rejects the string | `refusal_order` | `server-windows` (`update_thread.rs:590`) |
| Structural — no locator field can be added | `update_types_carry_no_locator_field` | `server-core --test update_guard` |

## For the Next Plan

- **`SERVER_PROTO_VERSION` is now `"1.8"`.** Any new fixture or test asserting the current version must use 1.8. The handshake still compares only the MAJOR component, so a 1.0-advertising phone still connects — `hello_challenge` in `integration.rs` deliberately still pins `"1.0"`.
- **`protocol/schema/mouse-binary.md`'s title still reads `protoVersion 1.7`.** That is correct — it names the version the `0x03` opcode was introduced in, not the current one. Do not "fix" it.
- **`router.rs` has no update placeholder left.** Both arms are live. `is_executor_bound`'s doc comment is now the authoritative statement of the exemption rule AND its one counter-example.
- **`update/mod.rs`'s `#![allow(dead_code)]` is still there** and its removal is still 12-17's. This plan added no caller for `UpdateCmd::Check`, `marker::write_pending`, `download::download_to` or `feed::APK_ASSET_PREFIX` — re-probe rather than assume.
- **`Harness.update_exec` exists now.** Any later socket test needing to seed `info()` or read `applies()` uses it; do not construct a second `MockUpdate`.
- **A heredoc append to a Rust test file fails in this shell.** Use the Write tool into the scratchpad plus `cat >>`.

## Self-Check: PASSED

All six modified files present, all three commits found in `git log`, `cargo test --workspace` 300 passed / 0 failed / 2 ignored, `cargo build --workspace` exit 0 with zero warnings.
