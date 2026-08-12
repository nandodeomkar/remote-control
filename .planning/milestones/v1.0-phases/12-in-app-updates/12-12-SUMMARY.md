---
phase: 12-in-app-updates
plan: 12
subsystem: infra
tags: [rust, wiring, composition-root, watch, relay, executors, serverdeps, ext-version]

# Dependency graph
requires:
  - phase: 12-04
    provides: UpdateExecutor trait, UpdateProgress/UpdateInfo/ExtInfo, MockUpdate
  - phase: 12-11
    provides: WinUpdate, run_update_thread, UpdateCmd, the D-15 refusal ladder
provides:
  - "Executors.update — the wire's ONE route into the update path"
  - "ServerDeps.update — the update.progress watch seam (no session arm yet; 12-13's)"
  - "run_ext's third relay watch (ext_tx) and the ext.hello extVersion capture"
  - "reset_relay_watches over all THREE watches — the single session-death cleanup point"
  - "main.rs step 3e — the update thread spawn, the shared Arc progress Sender and busy flag"
affects: [12-13, 12-15, 12-16, 12-17, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A ServerDeps field bound by NAME (not swallowed by `..`) at the accept-loop destructure, so a future field addition still has to be handled explicitly even while its consumer is a plan away"
    - "A shared watch Sender wrapped in Arc so a SLOW producer (the thread) and a FAST one (the executor's immediate refusals) can both publish onto one seam"

key-files:
  created: []
  modified:
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/executors/mock.rs
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/src/transport/ext.rs
    - server/server-core/tests/integration.rs
    - server/server-core/tests/ext_relay.rs
    - server/server-windows/src/main.rs
    - server/server-windows/src/update/mod.rs

key-decisions:
  - "ExtInfo is NOT a ServerDeps field. ServerDeps fields exist to drive session push arms; ExtInfo drives none — its only consumer is WinUpdate, which takes its own Receiver clone in main.rs"
  - "listener.rs binds `update` by name as `update: _update` rather than adding a `..` rest pattern, so the exhaustive-destructure property that made this plan's compile errors informative survives into 12-13"
  - "The progress watch Sender is an Arc shared between the thread and WinUpdate, because a busy/downgrade/stale refusal must reach the phone WITHOUT queueing behind an in-flight 5 MB download"
  - "update/mod.rs's `#![allow(dead_code)]` stays: probed with it removed, four items in the subtree still have no caller. Removal point moved from 12-12 to 12-17 with the list spelled out"

patterns-established:
  - "Three-watch reset asserted in ONE observation: wait on the LAST watch reset in source order, then read the other two synchronously — because reset_relay_watches sends all three before returning, so the sites cannot have drifted"

requirements-completed: [D-05, D-09, D-12, D-14, D-18, SC5, SC7]

# Metrics
duration: 18min
completed: 2026-08-04
---

# Phase 12 Plan 12: Wiring the Update Path Summary

**Three seams opened at once because the compiler forced them to — `Executors.update`, `ServerDeps.update` and a third relay watch — and the composition root gained a fourth worker thread in the shape of the three it already had.**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-08-04T19:13Z
- **Completed:** 2026-08-04T19:31Z
- **Tasks:** 3
- **Files modified:** 9 (0 created, 9 modified)

## Accomplishments

- `Executors.update` and `ServerDeps.update` exist and are correct, and every harness constructs them. `cargo test --workspace` is **293 passed / 0 failed / 2 ignored** (was 290 at the 12-11 baseline), `cargo build -p server-windows` exit 0, **zero warnings anywhere**.
- The server now knows which extension build is running: `ext.hello`'s `extVersion` lands in a third relay watch, and `WinUpdate::info` already reads it (12-11 wrote that side against a watch nothing produced into — as of this plan it is live).
- `reset_relay_watches` takes all three senders. Its own doc said a future relay watch must be added THERE and nowhere else; that is exactly what happened, and the three-watch reset is asserted in ONE test observation so the sites cannot drift apart.
- **Mutation-proven RED:** deleting the single `ext_tx.send(ExtInfo::default())` line fails exactly `ext_disconnect_resets_all_three_watches` and nothing else (18 passed / 1 failed). Source restored byte-identical after, verified by `diff`.
- D-14 held: the only new route from the wire to the update path is `Executors.update`, whose `apply` is still one `&str`. No field, parameter or channel added in this plan can carry a locator.
- `main.rs`'s diff is seven hunks — two import lines, the relay-watch pair, the step 3e block, the `Executors` literal, the `ServerDeps` literal and the `run_ext` call. The router, the session and all four existing thread blocks are byte-untouched.

## Task Commits

1. **Task 1: Executors.update, ServerDeps.update, and the harnesses** — `36d7670` (feat)
2. **Task 2: The third relay watch — ext.hello's extVersion** — `af5c9e6` (feat)
3. **Task 3: main.rs — spawn the thread and wire both bundles** — `f742915` (feat)

## Files Created/Modified

- `server/server-core/src/executors/mod.rs` — `Executors.update: Arc<dyn UpdateExecutor>`, with the T-12-01 note on the field: it is the wire's one and only route into the update path, and there is deliberately no second entry point and no locator parameter.
- `server/server-core/src/transport/mod.rs` — `ServerDeps.update: watch::Receiver<UpdateProgress>`, doc-commented in the established discipline (producer named, no-snapshot stated and justified, empty-stage sentinel explained).
- `server/server-core/src/transport/listener.rs` — the accept-loop destructure binds `update: _update` with a comment pointing at 12-13. **Not in the plan's file list; required to compile** (see Deviations).
- `server/server-core/src/executors/mock.rs` — `recording()` supplies a fresh `MockUpdate`, with a doc note on why the `update` slot is the ONE field that is not the shared recorder.
- `server/server-core/src/transport/ext.rs` — `run_ext` takes `ext_tx`; its watch-channel contract doc grew to three watches; `handle_ext_text` takes `ext_tx`; the `"ext.hello" => None` arm became a version capture; `reset_relay_watches` takes and resets all three.
- `server/server-core/tests/integration.rs` — both `ServerDeps` constructions carry `update`; the `Harness` gained `_update_tx` as a **struct field** (the `bm_tx` precedent — a local would drop at `start_server`'s exit and silently disable the branch 12-13 adds).
- `server/server-core/tests/ext_relay.rs` — `Relay.ext_rx`, a `wait_ext_watch` helper, and three new socket cases (19 tests, was 16).
- `server/server-windows/src/main.rs` — step 3e (the update thread), the ext-info relay watch pair, `WinUpdate` in the bundle, `update_rx` in `ServerDeps`, the new `run_ext` argument.
- `server/server-windows/src/update/mod.rs` — comment-only: the `#![allow(dead_code)]` removal point corrected from 12-12 to 12-17 (see Deviations).

## Decisions Made

1. **`ExtInfo` is NOT a `ServerDeps` field.** The plan asked for the choice to be made and recorded. `ServerDeps` fields exist for one purpose — to drive an authed-gated session push arm — and `ExtInfo` drives none: the phone learns `extConnected`/`extVersion` from an `update.status` REPLY, not from a push. Its only consumer is `WinUpdate`, which takes its own `Receiver` in `main.rs`. Adding it to `ServerDeps` would have put a field in the transport tier that the transport tier never reads, and would have needed threading through `listener.rs` and `run_session` for nothing.
2. **`listener.rs` binds the new field by name rather than adding `..`.** A rest pattern would have been the smaller diff, but the exhaustive destructure is load-bearing: it is what turned this plan's `ServerDeps` change into a compile error at the one place 12-13 must edit, instead of a silently-ignored field. `update: _update` keeps that property.
3. **The progress watch Sender is an `Arc`, cloned onto the thread rather than moved.** This is the one departure from the 3a-3c three-line shape and it is required by 12-11's design: `WinUpdate` publishes the pre-fetch refusals (`busy`, `downgrade`, `stale`) itself so a second tap is answered immediately, not when a 5 MB download finishes. The `busy` flag is shared for the mirror reason — the thread clears it at its single exit site.
4. **`update: update_rx` moves rather than `update_rx.clone()`.** The plan's sketch said `.clone()`; the sibling fields (`tabs: tabs_rx`, `bookmarks: bm_rx`) all move, and nothing else in `main` reads the receiver. A clone would leave a live handle for the process lifetime for no reader. Same reasoning for `ext_info_rx`.
5. **The three-watch reset is one observation, not three.** `reset_relay_watches` sends all three before it returns, so waiting on the LAST one in source order and then reading the other two synchronously is sound — and it is what makes the test capable of failing if any single site is missed, which the mutation run proved.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `listener.rs` destructures `ServerDeps` exhaustively**

- **Found during:** Task 1
- **Issue:** `accept_loop` binds every `ServerDeps` field by name (no `..`), so adding `update` broke the build in a file the plan's `files_modified` did not list. There is no way to add a `ServerDeps` field without touching it.
- **Fix:** Added `update: _update` with a comment naming 12-13 as the consumer and stating why the binding is by name rather than `..`. No behaviour change — the value is bound and dropped.
- **Files modified:** `server/server-core/src/transport/listener.rs`
- **Verification:** `cargo test -p server-core` green; the accept loop and `run_session`'s signature are otherwise byte-untouched.
- **Committed in:** `36d7670` (Task 1 commit)

**2. [Rule 1 - Doc defect] `update/mod.rs`'s `dead_code` note named the wrong removal point**

- **Found during:** Task 3
- **Issue:** 12-11 left `#![allow(dead_code)]` with the instruction "REMOVE this allow in 12-12, once the bundle wiring gives every public item in this subtree a real caller", and 12-11's own summary repeated it as a carry-forward. Probed by removing the allow and building: **four items still have no caller** — `UpdateCmd::Check` (12-17's settings window), `marker::write_pending`, `download::download_to` and `feed::APK_ASSET_PREFIX`. Acting on the instruction would have introduced four warnings; leaving it silently wrong would send 12-17 the same way.
- **Fix:** Comment-only edit. The removal point is now 12-17, with the four surviving items listed by name and reason, plus an instruction to re-probe rather than assume.
- **Files modified:** `server/server-windows/src/update/mod.rs`
- **Verification:** `cargo build -p server-windows` exit 0 with zero warnings; the probe's four warnings are recorded above verbatim.
- **Committed in:** `f742915` (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 doc defect)
**Impact on plan:** No scope creep and no behaviour change from either. Both are single-hunk edits in files the plan did not list, and both were forced — one by the compiler, one by an instruction in the source that had become false.

## Intermediate Build State (recorded per Task 1's acceptance criteria)

After Task 1 (`36d7670`) the workspace deliberately did not build: `cargo build -p server-windows` failed with **exactly two errors and nothing else** —

```
error[E0063]: missing field `update` in initializer of `Executors`
error[E0063]: missing field `update` in initializer of `ServerDeps`
```

Task 3 (`f742915`) closes both. The workspace builds and tests clean at plan end; the break existed only across two intermediate commits, which is the cost of committing each task atomically rather than squashing the wiring into one.

## Issues Encountered

- **A Python round-trip rewrote `ext.rs` line endings.** The mutation proof used a small Python script to comment out one line; Python's default text-mode write converted the whole LF file to CRLF, so `diff` reported all 430 lines changed after the "restore". Resolved by restoring from a `cp` backup taken before the mutation and confirming `git diff --numstat` showed the real scoped change (59/16). Worth remembering: use `newline=''` (or `sed -i`) for in-place source mutation on this repo.

## Verification Results

| Check | Result |
|---|---|
| `cargo test --workspace` | 293 passed / 0 failed / 2 ignored (was 290) |
| `cargo build -p server-windows` | exit 0, zero warnings |
| `grep -c 'pub update' server-core/src/executors/mod.rs` | 1 |
| `grep -c 'pub update' server-core/src/transport/mod.rs` | 1 |
| `grep -c 'extVersion' server-core/src/transport/ext.rs` | 4 |
| `grep -c 'ExtCmd::Reload' server-core/src/transport/ext.rs` | 0 (12-16's work) |
| `grep -c 'run_update_thread' server-windows/src/main.rs` | 1 |
| `grep -c 'WinUpdate::new' server-windows/src/main.rs` | 1 |
| `cargo test -p server-core --test ext_relay` | 19 passed (was 16, +3) |
| Three-watch reset mutation | RED confirmed: 18 passed / 1 failed |

## Known Stubs

None. Every field added by this plan has a real producer or a real consumer as of this commit:

- `Executors.update` → `WinUpdate` (real), read by the router in 12-13.
- `ServerDeps.update` → the real update thread; **no session arm yet, by plan design** (12-13 adds it). This is a deliberate wiring-before-behaviour split stated in the plan objective, not an unwired stub: the watch is live and the producer is real.
- The ext-info watch → `run_ext` produces, `WinUpdate::info` consumes. Both ends real today.

## Next Phase Readiness

**For 12-13 (the router arms and the session push):**

- `router.rs` still holds the wave-2 documented placeholder `UpdateCheck`/`UpdateApply => Vec::new()`. `Executors.update` now exists, so replacing it is unblocked. It is deliberately NOT `err{unknownType}` — a false `unknownType` is what the phone caches as "server too old to update itself" (SPEC §10).
- `Msg::UpdateCheck` and `Msg::UpdateApply` must BOTH join `is_executor_bound`'s `matches!` list (CONTEXT D-13: `update.check` IS executor-bound, unlike every other `*.list` read — amend the doc comment at `router.rs:344`, do not silently contradict it).
- **The session arm must skip the empty-stage sentinel.** `UpdateProgress::default()` has an empty `stage` and is never legal on the wire; the field's doc in `transport/mod.rs` and `executors/mod.rs` both say so.
- The one place to thread it: `listener.rs`'s `update: _update` binding, then a `let update = update.clone();` in the loop and a parameter on `run_session` — exactly how `bookmarks` is done, four lines away in each case.
- `integration.rs`'s `Harness._update_tx` is already the live producer end; 12-13's suite renames it (drop the `_`) and drives pushes through it. Keep it a struct field.

**For 12-16 (`ext.reload`):**

- The version the extension reports is now in the watch, so the D-18 comparison has its input. `ExtCmd::Reload`, the comparison and the once-per-target-version guard are all still absent — `grep -c 'ExtCmd::Reload' ext.rs` returns 0 — as its Chrome-file-locking observation checkpoint requires.
- T-12-40 is an ACCEPTED residual: `extVersion` is attacker-controllable by any local process that can open the loopback socket. The bound is that a forged value can only mis-render one row or trigger at most one `ext.reload` per target version per process run.

**For 12-17 (the PC settings window):**

- `update/mod.rs`'s `#![allow(dead_code)]` is yours to remove. `UpdateCmd::Check` is the last item that needs a caller; re-probe the other three (`marker::write_pending`, `download::download_to`, `feed::APK_ASSET_PREFIX`) rather than assuming they are still uncalled.
- The update thread's command sender is consumed by `WinUpdate` in `main.rs`. A settings window that wants to command the thread directly needs its own clone taken **before** the `Executors` literal — and note 12-11's finding that `run_apply` re-runs the refusal ladder at its own door precisely because a second caller was expected.

**Untested at runtime, by design:** the thread is spawned but nothing on the wire reaches it yet (the router placeholder is 12-13's to replace), and the real `ureq` calls remain 12-18's on-hardware UAT.

## Self-Check: PASSED

- `server/server-core/src/transport/ext.rs` — FOUND, contains `extVersion` (4 occurrences)
- `server/server-windows/src/main.rs` — FOUND, contains `run_update_thread` (1) and `WinUpdate::new` (1)
- `Executors.update` — FOUND (`grep -c 'pub update'` = 1 in `executors/mod.rs`)
- `ServerDeps.update` — FOUND (`grep -c 'pub update'` = 1 in `transport/mod.rs`)
- `reset_relay_watches` — FOUND, takes three senders, resets three
- Commits `36d7670`, `af5c9e6`, `f742915` — all FOUND in git history
- `cargo test --workspace` — 293 passed / 0 failed / 2 ignored
- `cargo build -p server-windows` — exit 0, zero warnings

---
*Phase: 12-in-app-updates*
*Completed: 2026-08-04*
