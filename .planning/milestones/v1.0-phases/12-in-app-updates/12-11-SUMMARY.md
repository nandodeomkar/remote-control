---
phase: 12-in-app-updates
plan: 11
subsystem: infra
tags: [rust, update, thread, mpsc, watch, ureq, security, refusal-ladder]

# Dependency graph
requires:
  - phase: 12-04
    provides: UpdateExecutor trait, UpdateProgress/UpdateInfo/LastUpdate/ExtInfo, server_core::version::compare_versions
  - phase: 12-06
    provides: feed.rs (fetch_latest, resolve_asset, the compiled-in locator) and download.rs (download_to, verify_or_delete, temp_path_for, is_valid_target)
  - phase: 12-09
    provides: apply.rs (begin_apply, the detached helper) and marker.rs (take_marker, write_pending, truncate_update_log_if_large)
provides:
  - "update_thread.rs — UpdateCmd, run_update_thread, and the D-15 refusal ladder as pure functions"
  - "pre_fetch_refusal / post_fetch_refusal / is_valid_target re-export — the whole ladder, no I/O"
  - "should_emit_pct / pct_of — the pure 1%/250 ms progress throttle"
  - "STAGE_* consts — the closed D-10 stage vocabulary, spelled once for both publishing surfaces"
  - "WinUpdate + impl UpdateExecutor for WinUpdate — the only update surface the wire can reach"
  - "feed::resolve_setup — asset resolution without exposing the asset-name prefix"
  - "download::download_to_with_progress — the byte callback the downloading stage needs"
affects: [12-12, 12-13, 12-15, 12-17, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Injectable I/O seam (ApplyOps trait) so an ordered security-critical pipeline is testable with no socket, no disk and no spawned installer"
    - "Injectable publication sink (&mut dyn FnMut(UpdateProgress)) because a watch COALESCES and a test must observe the SEQUENCE of stages, not just the last one"
    - "Single-clear-site busy guard: one call site after the pipeline means every early return is covered by construction, not by a checklist"

key-files:
  created:
    - server/server-windows/src/update/update_thread.rs
  modified:
    - server/server-windows/src/update/mod.rs
    - server/server-windows/src/update/feed.rs
    - server/server-windows/src/update/download.rs

key-decisions:
  - "The refusal ladder is three pure functions with zero I/O, so a forged URL-shaped target costs the machine no network activity at all (SC6/T-12-01) and the ORDER is asserted by a test that sets all three conditions at once"
  - "is_valid_target is RE-EXPORTED from download.rs rather than re-implemented; version ordering calls server_core::version::compare_versions — the same comparator the phone is pinned to via 10-version-compare.json"
  - "A malformed target is refused as `stale` (the D-11 vocabulary is closed and has no shape code) and is NEVER echoed back as `version` — a refusal must not become a reflection"
  - "The process exit uses the crate's existing std::process::exit path (the tray Quit arm) after a 750 ms flush grace, NOT a plumbed-through graceful shutdown: the detached helper is already counting down its bounded 30-poll wait"
  - "UpdateCmd::Check's terminal is `uptodate` in BOTH outcomes because D-10 is closed and has no `available` stage; the resolved version is carried ONLY when it is strictly newer, so version-present IS the available signal for 12-17"
  - "busy is cleared at ONE site in the loop rather than on each of run_apply's seven exits (T-12-37)"

patterns-established:
  - "ApplyOps: the blocking steps of a pipeline behind a trait, with the PURE steps (asset resolution) deliberately left out so the locator can never be injected"
  - "Three private UpdateProgress constructors are the only builders in the module, making 'pct only on downloading' and 'error always from UpdateError::code' true by construction"

requirements-completed: [D-05, D-11, D-12, D-14, D-15, D-16, D-22, D-23, D-24, D-26, SC5, SC6]

# Metrics
duration: 32min
completed: 2026-08-04
---

# Phase 12 Plan 11: The Update Thread and WinUpdate Summary

**The whole PC update pipeline assembled: a dedicated OS thread that owns every blocking step in the D-15 order, a refusal ladder of pure functions whose ORDER is a tested property, and `WinUpdate` — the only update surface the wire can reach.**

## Performance

- **Duration:** ~32 min
- **Started:** 2026-08-04T13:08Z
- **Completed:** 2026-08-04T13:40Z
- **Tasks:** 3
- **Files modified:** 4 (1 created, 3 modified)

## Accomplishments

- `pre_fetch_refusal` runs `busy` → target shape → downgrade in that exact order with **zero I/O**, so `update.apply {target: "https://evil/x.exe"}` is refused as `stale` without a single packet leaving the machine — asserted by a test double that PANICS if the feed is fetched.
- `run_apply` is the ordered pipeline (checking → fetch → stale-check → resolve → download → verify → hand-off → restarting), and every failing step publishes exactly one terminal and stops. `begin_apply` is unreachable from any earlier failure branch, asserted per-step.
- The `busy` guard is cleared at one call site covering all seven of `run_apply`'s exits, proven by two tests that drive a failing and a refused pipeline and observe the flag afterwards.
- Three private `UpdateProgress` constructors make D-10/D-11 structural: `pct` exists only on `downloading`, `error` only on `failed` and only from `UpdateError::code`. `grep -c '"network"\|"checksum"\|"disk"' update_thread.rs` returns 0.
- `WinUpdate::info` reports `env!("CARGO_PKG_VERSION")` (D-05) and **takes** the marker, so an outcome reaches exactly one `update.status` and never again (D-12).
- Rust workspace suite: **290 passed / 0 failed / 2 ignored** (was 246 at the wave-2 baseline), `cargo build --workspace` clean, `main.rs` untouched.

## Task Commits

1. **Task 1: The refusal ladder as pure functions** — `79e6d65` (feat)
2. **Task 2: The update thread and its apply pipeline** — `e2d2d78` (feat)
3. **Task 3: WinUpdate — the UpdateExecutor implementation** — `cf743a6` (feat)

## Files Created/Modified

- `server/server-windows/src/update/update_thread.rs` — **created.** The module header states the rule it exists for: all blocking update work on a dedicated OS thread, never on the tokio runtime, because `ureq` is blocking and a ~5 MB download would stall a runtime worker for its whole duration. Contains `UpdateCmd`, the refusal ladder, the `STAGE_*` vocabulary, the pure progress throttle, the `ApplyOps` seam, `run_check`, `run_apply`, `run_update_loop` and `run_update_thread`.
- `server/server-windows/src/update/mod.rs` — `pub mod update_thread;`, plus `WinUpdate` and `impl UpdateExecutor for WinUpdate`. The `#![allow(dead_code)]` note now names 12-12 as its removal point (this is a binary crate, so `pub` buys no dead-code exemption and `WinUpdate` has no caller until the bundle wiring lands).
- `server/server-windows/src/update/feed.rs` — added `resolve_setup`, which resolves this platform's installer asset **without exposing `SETUP_ASSET_PREFIX`**. The prefix stays private to the module D-14 designates as the locator authority.
- `server/server-windows/src/update/download.rs` — added `download_to_with_progress` (cumulative-bytes callback); `download_to` now delegates to it with a no-op. The transfer loop became a 64 KiB chunked read/write so the caller can watch it advance; read failures still classify as transport and write failures as disk.

## Decisions Made

1. **A malformed target is `stale`, and is never reflected.** The D-11 vocabulary is closed and has no shape/parse code, and "that is not the version I resolved" is truthful about a target the server cannot even parse. `safe_version` returns `None` for anything that is not three integers, so a hostile string cannot travel back to the phone's Updates screen inside the refusal that rejected it.
2. **Process exit is `std::process::exit(0)` after a 750 ms grace.** The alternative — returning a signal for `main` to unwind gracefully — would have to be plumbed through the shell's winit loop on another thread, and any failure in that plumbing leaves the detached helper timing out against its bounded 30-poll wait and the update silently not happening. The grace window exists so the session loop can flush `restarting` before the socket drops (D-17); without it the phone's last observed stage is `installing`.
3. **`UpdateCmd::Check` terminates on `uptodate` in both outcomes.** D-10 is a closed vocabulary with no `available` stage, and inventing one means amending SPEC §7, the schema and both codecs first. The `version` field carries the distinction instead: present ⇒ this is the strictly-newer version the SERVER resolved (12-17's `Update now` target); absent ⇒ nothing newer, and the consumer renders its own `CARGO_PKG_VERSION`.
4. **`ApplyOps` injects the blocking steps but NOT asset resolution.** `feed::resolve_setup` is pure and stays a direct call: making it injectable would make the locator injectable, which is the one thing D-14 forbids.
5. **The publication sink is a `FnMut`, not the `watch::Sender`.** A `watch` coalesces by design, so a test holding a receiver can only see the last stage — and the SEQUENCE is exactly what D-10 constrains.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `download_to` had no progress callback**

- **Found during:** Task 2 (the apply pipeline)
- **Issue:** The plan requires the `downloading` stage to report progress and to throttle it at ~1 %/250 ms, but 12-06's `download_to` streams with `io::copy` and reports nothing. Progress could not be observed without either duplicating the download logic in `update_thread` (unacceptable — two transfer paths, one of them untested) or adding a callback.
- **Fix:** Added `download::download_to_with_progress(agent, url, dest, &mut dyn FnMut(u64))` with a 64 KiB chunked read/write loop; `download_to` now delegates with a no-op callback. The callback is deliberately unthrottled — throttling is a policy about a `watch` channel that `download.rs` knows nothing about, so it belongs to the caller.
- **Files modified:** `server/server-windows/src/update/download.rs`
- **Verification:** All eleven pre-existing `download` tests still pass unchanged; the read/write error classification (transport vs disk) is preserved and still routes through `classify_io`.
- **Committed in:** `e2d2d78` (Task 2 commit)

**2. [Rule 3 - Blocking] `SETUP_ASSET_PREFIX` was private to `feed`**

- **Found during:** Task 2
- **Issue:** Step 4 of the pipeline calls `feed::resolve_asset` "for the setup prefix", but that constant is module-private. Copying the prefix into `update_thread` would create a second locator site, which is exactly what D-14 forbids; widening the constant to `pub(crate)` would let any caller name a different file.
- **Fix:** Added `feed::resolve_setup(&Release)`, a two-line wrapper that keeps the prefix private and gives the pipeline a call that cannot be parameterised with someone else's name.
- **Files modified:** `server/server-windows/src/update/feed.rs`
- **Verification:** `cargo test -p server-windows update` green; the D-14 locator test (`feed_locator_is_the_compiled_in_release_repo`) and the prefix-disjointness test are untouched and still pass.
- **Committed in:** `e2d2d78` (Task 2 commit)

**3. [Rule 2 - Missing Critical] A rejected target must not be echoed back on the wire**

- **Found during:** Task 2
- **Issue:** The plan says every published value "carries `version` for the target being applied where it is known". Taken literally on the refusal path, that publishes the attacker-supplied string back to the phone's Updates screen — a refusal turned into a reflection.
- **Fix:** `safe_version` gates the field on `is_valid_target`, so a malformed target publishes `version: None`. Asserted in both `update_apply_refuses_a_forged_target_without_touching_the_feed` and `win_update_apply_refuses_a_forged_target_without_touching_the_thread`.
- **Files modified:** `server/server-windows/src/update/update_thread.rs`
- **Verification:** Named tests assert `published[0].version == None` for four hostile shapes.
- **Committed in:** `e2d2d78` (Task 2 commit)

**4. [Rule 2 - Missing Critical] The thread re-runs the ladder at its own door**

- **Found during:** Task 2
- **Issue:** `WinUpdate::apply` validates the target, but 12-17's settings window will command the same thread directly. Both dangerous interpolations (the `%TEMP%` filename and the helper's `set "TARGET=..."` line) are downstream of `run_apply`, and a validator that only one of two callers runs is not a validator.
- **Fix:** `run_apply` opens with `pre_fetch_refusal(false, target, running)` — the `busy` half is the caller's, the shape and ordering halves are re-checked here.
- **Files modified:** `server/server-windows/src/update/update_thread.rs`
- **Verification:** `update_apply_refuses_a_forged_target_without_touching_the_feed` drives `run_apply` directly (not through `WinUpdate`) and asserts no I/O step ran.
- **Committed in:** `e2d2d78` (Task 2 commit)

**5. [Rule 1 - Minor] `is_valid_target` re-exported rather than redefined**

- **Found during:** Task 1
- **Issue:** The plan asks for `pub fn is_valid_target` in `update_thread.rs`, but 12-06 already made `download::is_valid_target` public precisely so later plans would not invent a second version regex (recorded in STATE.md as a wave-2 carry-forward). Two validators are two answers to "what is a legal target", and an attacker gets to use the weaker one.
- **Fix:** `pub use super::download::is_valid_target;` with the rationale in its doc comment. All the plan's acceptance criteria for the function hold on the re-export.
- **Files modified:** `server/server-windows/src/update/update_thread.rs`
- **Verification:** `refusal_rejects_every_hostile_target_shape` exercises twelve shapes through the re-export.
- **Committed in:** `79e6d65` (Task 1 commit)

**6. [Rule 1 - Minor] `send` instead of `try_send` on the command channel**

- **Found during:** Task 3
- **Issue:** The plan specifies `try_send`, but `std::sync::mpsc::Sender` has no such method — the channel is UNBOUNDED, so `send` is already non-blocking and fails only when the receiver is gone.
- **Fix:** Used `send` with the house send-and-forget handling (clear `busy`, publish `installer`, log), documented on the field so the difference from `TabsRelay`'s bounded tokio `try_send` is explicit.
- **Files modified:** `server/server-windows/src/update/mod.rs`
- **Verification:** `win_update_apply_clears_busy_when_the_thread_is_gone`.
- **Committed in:** `cf743a6` (Task 3 commit)

---

**Total deviations:** 6 auto-fixed (2 blocking, 2 missing-critical, 2 minor)
**Impact on plan:** No scope creep. Two additions to sibling modules (`feed::resolve_setup`, `download::download_to_with_progress`) were the only way to build the pipeline without duplicating the locator or the transfer loop; both are additive and left every pre-existing test passing unchanged. The two security additions tighten the plan rather than widening it.

## Issues Encountered

- **A `watch` cannot be used to observe a sequence.** The first sketch had `run_apply` publish straight into the `watch::Sender`, which made "assert the ordered stages" untestable — the channel coalesces, so a receiver sees only the last value. Resolved by injecting the sink as `&mut dyn FnMut(UpdateProgress)`; `run_update_thread` passes a closure that sends into the watch. This is worth remembering for any future stage-sequence assertion.
- **A partially-moved harness.** `win_update_apply_clears_busy_when_the_thread_is_gone` needs the command RECEIVER dropped, which the shared test harness owns; the test builds its channels by hand instead.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

**Ready for 12-12 (the bundle wiring), which is the only thing standing between this code and a working update:**

- `WinUpdate::new(cmd, progress, busy, ext)` takes four injected handles. `main.rs` needs the three-line thread boilerplate from RESEARCH Pattern 1: an `mpsc::channel::<UpdateCmd>()`, a `watch::channel(UpdateProgress::default())` whose **sender is wrapped in an `Arc`** (both the thread and the executor hold it), an `Arc<AtomicBool>` for `busy`, and a `watch::Receiver<ExtInfo>` from the ext relay.
- **`main.rs` is byte-untouched by this plan**, as the plan required. `git diff server/server-windows/src/main.rs` is empty.
- **12-12 must also replace `router.rs`'s documented `UpdateCheck`/`UpdateApply => Vec::new()` placeholder** (the wave-2 carry-forward) now that `Executors.update` can exist, and **remove `update/mod.rs`'s `#![allow(dead_code)]`** once every public item in the subtree has a caller.
- **The session push arm** must skip the empty-stage sentinel (`UpdateProgress::default()` has an empty `stage` and is never sent), exactly as `server-core`'s type documentation says.

**For 12-17 (the PC settings fallback):**

- The stage vocabulary is `update_thread::STAGE_*` — use the consts, do not re-spell the literals.
- The `Check` terminal is `uptodate` in both outcomes; **`version` present means an update is available** and is the only legal `Apply` target. `version` absent means up to date, and the window renders its own `env!("CARGO_PKG_VERSION")` beside that copy.
- `should_emit_pct`/`pct_of` are public if the window wants the same throttle semantics.

**For 12-13/12-15 (the phone's Updates screen):** a PC-initiated check publishes `uptodate` carrying a version NEWER than the server's own. If the phone renders `uptodate` as "Up to date" without looking at `version`, a settings-window check performed while the phone is watching will briefly show the wrong sentence. It self-corrects on the phone's next own check. Worth one line of handling.

**Untested at runtime, by design:** `RealOps::exit_process` (it ends the process) and the real `ureq` calls. Both are exercised by 12-18's on-hardware UAT, which is where the whole pipeline first runs against a real feed.

## Self-Check: PASSED

- `server/server-windows/src/update/update_thread.rs` — FOUND (contains `run_update_thread`)
- `server/server-windows/src/update/mod.rs` — FOUND (contains `WinUpdate`, `impl UpdateExecutor for WinUpdate` × 1)
- Commits `79e6d65`, `e2d2d78`, `cf743a6` — all FOUND in git history
- `cargo test --workspace` — 290 passed / 0 failed / 2 ignored
- `cargo build -p server-windows` — exit 0, `git diff server/server-windows/src/main.rs` empty

---
*Phase: 12-in-app-updates*
*Completed: 2026-08-04*
