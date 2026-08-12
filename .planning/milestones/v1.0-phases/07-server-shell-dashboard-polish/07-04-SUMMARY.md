---
phase: 07-server-shell-dashboard-polish
plan: 04
subsystem: input
tags: [rust, windows, uipi, integrity-level, token, sendinput, detection]

# Dependency graph
requires:
  - phase: 07-server-shell-dashboard-polish
    plan: "07-03"
    provides: "server-windows Cargo.toml windows-crate feature set + SHARED-E OpenProcess/token discipline this plan extends (Cargo.toml co-location only, no logical dependency)"
provides:
  - "input_thread::is_blocking_il(foreground_rid, our_rid) -> bool — pure, unit-tested UIPI-block predicate"
  - "input_thread::foreground_integrity_rid() -> Option<u32> — Win32 foreground-process integrity RID reader"
  - "input_thread::our_integrity_rid() -> Option<u32> — our own process's integrity RID"
  - "input_thread::foreground_blocked() -> bool — combined detection helper"
affects: [07-06 composition-root wiring (debounced blocked-watch epoch + session.rs input.blocked push)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Proactive Win32 integrity-level comparison in place of a reactive SendInput-return check (SendInput cannot report UIPI drops)"
    - "OpenProcess ERROR_ACCESS_DENIED-as-signal: an inaccessible foreground process handle is itself evidence of higher integrity"
    - "Fail-quiet Option<u32>/bool degrade-to-medium on any read failure, mirroring firewall.rs's Unknown discipline — an uncertain read is never treated as a block"

key-files:
  created: []
  modified:
    - server/server-windows/src/input_thread.rs

key-decisions:
  - "RID constants (SECURITY_MANDATORY_MEDIUM_RID/HIGH_RID) defined as plain crate-local u32 consts rather than importing windows::Win32::System::SystemServices — keeps is_blocking_il a zero-OS-dependency pure function (Task 1 compiles and tests with no windows-crate Win32 calls) and avoids a new Cargo.toml feature; values (0x2000/0x3000) match the real Win32 constants exactly"
  - "No Cargo.toml change needed — Win32_Security, Win32_System_Threading, and Win32_UI_WindowsAndMessaging (GetForegroundWindow/GetWindowThreadProcessId, OpenProcessToken/GetTokenInformation, GetSidSubAuthority*) were already enabled by 07-03 and earlier plans"
  - "foreground_blocked() degrades BOTH sides (foreground and our own RID) to SECURITY_MANDATORY_MEDIUM_RID on a read failure, not just the foreground side — a failed our_integrity_rid() read must never manufacture a spurious block either"

requirements-completed: [SRV-05]

# Metrics
duration: 5min
completed: 2026-07-12
---

# Phase 7 Plan 04: Proactive UIPI Detection Primitives Summary

**Pure `is_blocking_il` integrity-comparison predicate plus a Win32 foreground-integrity-RID reader (`OpenProcess`→`OpenProcessToken`→`GetTokenInformation(TokenIntegrityLevel)`), unit-tested and unwired — `run_input_thread`'s signature untouched, ready for 07-06 to debounce and push.**

## Performance

- **Duration:** 5 min
- **Tasks:** 2 (Task 1 followed the TDD RED/GREEN cycle; Task 2 was a straight `auto` build task)
- **Files modified:** 1 (`server/server-windows/src/input_thread.rs`)

## Accomplishments
- `is_blocking_il(foreground_rid, our_rid) -> bool` — pure predicate (`foreground_rid > our_rid`), TDD RED (stub `todo!()` + 3 failing tests) then GREEN (real one-line implementation).
- `SECURITY_MANDATORY_MEDIUM_RID` / `SECURITY_MANDATORY_HIGH_RID` crate-local consts shared by the predicate, its tests, and the Win32 helper.
- `foreground_integrity_rid()` — `GetForegroundWindow` → `GetWindowThreadProcessId` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` → `OpenProcessToken(TOKEN_QUERY)` → `GetTokenInformation(TokenIntegrityLevel)` → last SID sub-authority (the RID). `OpenProcess` returning `ERROR_ACCESS_DENIED` itself returns `Some(SECURITY_MANDATORY_HIGH_RID)` (Pitfall 6 signal); every other failure returns `None`.
- `our_integrity_rid()` — same token-read path on the `GetCurrentProcess` pseudo-handle.
- `foreground_blocked()` — combines the three above with fail-quiet `unwrap_or(SECURITY_MANDATORY_MEDIUM_RID)` degradation on either side.
- `read_integrity_rid(token)` — shared two-pass `GetTokenInformation` buffer-sizing helper extracting the mandatory-label SID's RID.
- All four new Win32-touching functions carry `#[allow(dead_code)]` naming 07-06 as the consuming plan (none are called yet — `run_input_thread`'s command loop is untouched).
- `cargo build -p server-windows` and `cargo test -p server-windows` both clean: 25 passed / 2 ignored, zero warnings.

## Task Commits

Each task was committed atomically:

1. **Task 1 RED — failing test for is_blocking_il** - `0d70bdc` (test)
2. **Task 1 GREEN — implement is_blocking_il** - `30fd74f` (feat)
3. **Task 2 — Win32 foreground integrity reader + foreground_blocked** - `3162be5` (feat)

## TDD Gate Compliance

Task 1 (`tdd="true"`) followed the mandatory RED → GREEN sequence:
- RED (`0d70bdc`): `is_blocking_il` stubbed with `todo!()`; three new unit tests asserting HIGH>MEDIUM blocks, MEDIUM==MEDIUM does not, LOW<MEDIUM does not — confirmed FAILED via `cargo test -p server-windows input_thread` (3 failed / 6 passed, the 6 being pre-existing unrelated tests).
- GREEN (`30fd74f`): real one-line implementation (`foreground_rid > our_rid`); confirmed 9/9 passed, no `REFACTOR` commit needed (implementation was already minimal).

## Files Created/Modified
- `server/server-windows/src/input_thread.rs` (modified) — added `is_blocking_il` + RID consts + 3 unit tests (Task 1); added `read_integrity_rid`, `foreground_integrity_rid`, `our_integrity_rid`, `foreground_blocked` + 4 new `windows` crate imports (Task 2). `run_input_thread`'s signature and `match cmd` loop are byte-identical to before this plan.

## Decisions Made
- RID constants live as plain `u32` crate-local consts (not imported from `windows::Win32::System::SystemServices`) so Task 1's predicate has zero OS/Win32 dependency and no new Cargo.toml feature — see key-decisions above.
- No `Cargo.toml` change was needed this plan; the plan anticipated possibly adding `Win32_Security`, but 07-03 (and earlier) had already enabled every feature this plan's Win32 calls require.
- `foreground_blocked()` fails quiet on both operand reads, not only the foreground side, to avoid a spurious block from a transient failure reading our own token.

## Deviations from Plan

None — plan executed exactly as written. The plan's Cargo.toml note ("add whatever `windows` feature flags... e.g. Win32_Security if not already present") anticipated a possible addition that turned out unnecessary; this is not a deviation, just an anticipated need that the existing feature set already satisfied.

## Issues Encountered
None.

## User Setup Required
None — no external service configuration required. On-device validation of `foreground_blocked()` against a real elevated window is deferred to 07-06's phase gate per the plan's `<verification>` section.

## Next Phase Readiness
- **07-06 (composition-root wiring):** can call `foreground_blocked()` on a debounced Move/Click cadence, thread a `blocked: watch::Sender<u64>` into `run_input_thread` (new param — this plan deliberately left the signature untouched), and wire the resulting epoch to `session.rs`'s authed-gated `input.blocked` push branch (already landed in 07-02/07-05 per the protocol amendment).
- No blockers.

## Self-Check: PASSED

- `server/server-windows/src/input_thread.rs` exists and contains `fn is_blocking_il`, `fn foreground_integrity_rid`, `fn foreground_blocked`, `fn our_integrity_rid` — confirmed via grep.
- Task commits `0d70bdc`, `30fd74f`, `3162be5` all present in `git log`.
- `cargo build -p server-windows` and `cargo test -p server-windows` both green post-implementation.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-12*
