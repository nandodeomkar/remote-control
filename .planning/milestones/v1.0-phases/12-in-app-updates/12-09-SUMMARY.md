---
phase: 12-in-app-updates
plan: 09
subsystem: server-windows
tags: [updates, marker, installer, detached-process, cmd-injection, d-12, d-16, d-24]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 06
    provides: "`update/mod.rs` with the `UpdateError` closed vocabulary, and `download::is_valid_target` — the `^\\d+\\.\\d+\\.\\d+$` predicate this plan reuses instead of inventing a second version regex"
  - phase: 12-in-app-updates
    plan: 04
    provides: "`server_core::executors::LastUpdate` — the type `take_marker` produces"
provides:
  - "`marker::write_pending` / `take_marker` — the pessimistic-write, read-and-delete lifecycle that carries an update outcome across the process swap (D-12)"
  - "`marker::marker_path` / `update_log_path` — the two runtime paths, resolved through `dirs::config_dir()` beside `config.toml` and the rolling server logs"
  - "`marker::truncate_update_log_if_large` — RESEARCH Open Question 4 resolved: the server empties `update.log` above 64 KiB"
  - "`apply::helper_script` — the pure, golden-tested `.cmd` text with a bounded PID wait, `/SUPPRESSMSGBOXES`, an unconditional relaunch and a self-delete"
  - "`apply::begin_apply` — the sequencing entry point (marker, script, detached spawn) that deliberately does NOT exit the process"
  - "`apply::installed_exe` / `helper_script_path` / the `DETACHED_PROCESS`+`CREATE_NO_WINDOW` pair"
affects: [12-10, 12-12, 12-13, 12-16, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pessimistic-first durable state: the failure record is written BEFORE the risky action, so every way the process can die leaves an honest record and only success can improve it"
    - "Delete-on-read, not delete-on-report: a consumed-once marker cannot be re-reported by a phone that reconnects weeks later"
    - "Generated-command-line as a pure function: the whole `.cmd` text is a `String` a unit test can assert over, so injection and control flow are provable without spawning anything"
    - "Injected-spawn seam: `begin_apply_with` takes every path AND the spawn closure, so the sequencing is testable without starting a detached process that installs software"

key-files:
  created:
    - server/server-windows/src/update/marker.rs
    - server/server-windows/src/update/apply.rs
  modified:
    - server/server-windows/src/update/mod.rs

key-decisions:
  - "`update.log` truncation was ADOPTED, not accepted-unbounded: RESEARCH Open Question 4 offered both, and the plan chose the 64 KiB startup truncate because the helper appends from a `cmd` process that cannot participate in `tracing-appender` rotation"
  - "The marker is validated on READ as if it came from outside — a malformed `target` is discarded and an out-of-vocabulary `error` collapses to `installer`, because the marker's contents travel to the phone through `update.status`"
  - "`take_marker` deletes the file BEFORE parsing it, so no early return can leave a consumed marker behind"
  - "The helper uses the `set \"NAME=VALUE\"` idiom rather than the research example's bare `set NAME=VALUE`: the quotes delimit the assignment without entering the value, so a space or an `&` cannot end the command"
  - "The script is emitted with CRLF line endings — cmd.exe's parenthesised `if` block parsing is only reliably specified for CRLF batch files"
  - "The success marker is written through the `%TARGET%` expansion rather than interpolating the version a second time, so there is one substitution site to validate"
  - "`begin_apply` does not call `exit`: the caller owns it so a final `update.progress {stage:\"restarting\"}` can reach the phone before the socket drops"

patterns-established:
  - "Acceptance criteria that are literal greps get their literals removed from comments, not their intent weakened (the 12-06 precedent, applied three more times here)"
  - "A cross-artifact string constant gets a pinned-string test naming the file that must change with it (the `mutex_name_matches_the_installer_contract` template, now also `installed_exe_name_matches_the_installer_contract`)"

requirements-completed: [D-12, D-16, D-23, D-24, SC5]

# Metrics
duration: 25min
completed: 2026-08-04
---

# Phase 12 Plan 09: The Marker and the Detached Helper Summary

**The server can now write an honest record of an update it will not live to see the end of, drop a self-deleting `.cmd` into `%TEMP%`, and hand off to a detached process that waits for its corpse before running the installer — with every branch of that script provable by a unit test that spawns nothing.**

## Performance

- **Duration:** ~25 min
- **Tasks:** 3 of 3
- **Files modified:** 3 (2 created, 1 modified)
- **Tests added:** 22 (9 marker, 13 apply) — workspace total now 268 passed / 0 failed / 2 ignored (was 246)

## Accomplishments

- **The marker is pessimistic by construction, not by convention.** `write_pending` writes `{target, ok:false, error:"installer"}` *before* anything risky happens, and `begin_apply` calls it as step 1. A test proves the property that matters: when the script write fails, `begin_apply` returns `installer` **and the marker is still on disk**. Every way the process can die from that point leaves an honest record, and the only thing that can improve it is the helper observing a zero installer exit.
- **An outcome is reported exactly once, and an absent marker is silent.** `take_marker` deletes the file *before* it parses it, so no early return can leave a consumed marker behind, and a second call returns `None`. The `NotFound` arm mirrors `config::load` exactly — no warn, no error, nothing on the wire. That is the D-12 rule that is easiest to get wrong in the other direction (delete-on-report would leave a permanent marker on a PC whose phone never reconnects).
- **The marker is treated as untrusted input, because its contents reach the phone.** A malformed `target` is discarded (it would otherwise travel into `update.status`), and an `error` outside the closed D-11 vocabulary collapses to `installer` rather than relaying whatever the file held — a code the phone does not know renders as nothing, and a path in that field would be exactly the leak T-12-06 forbids. Corrupt JSON, wrong types, an empty file and a truncated object all yield `None` *and* remove the file.
- **`/SUPPRESSMSGBOXES` is in the generated text and the reason is in the file.** The objective's correction (superseding the design spec) is recorded as a `//!` section and as a REM comment in the script itself: `/VERYSILENT` alone does not arm suppression of Inno's AppMutex `MB_OKCANCEL`, and the check runs before the `CloseApplications` stage. Both belts are present — the PID wait, and the flag that turns a still-held mutex into a decodable non-zero exit rather than a modal dialog parked on the desktop.
- **The `.cmd` control flow is proven, not eyeballed.** Three tests assert over the text's *ordering*, not just its contents: the `ok:true` rewrite appears exactly once and sits strictly between the failure path's `goto relaunch` and the `:relaunch` label (so D-24's failure branch cannot reach it); the failure branch logs before it jumps; and the wait-timeout branch precedes the setup invocation and jumps past it entirely. `"ok":true` occurs exactly once anywhere in the script.
- **A wire-shaped target cannot inject a command.** `helper_script` debug-asserts `is_valid_target` — the same predicate 12-06 made public precisely so this plan would not write a second regex — and a test proves `1.5.0" & calc &` panics rather than producing a script containing `calc`. A positive control asserts that an *accepted* target leaves exactly one ` & ` in the whole text: the self-delete idiom.
- **The spawn is detached, null-stdio and unwaited, and no test starts one.** `begin_apply_with` takes every path *and* the spawn closure, so the sequencing is exercised end-to-end with a stub that asserts the marker already exists by the time it is called. A detached child that installs software is not something a unit test may start, and none does.

## Task Commits

Each task was committed atomically:

1. **Task 1: marker.rs — the record that outlives the process** — `9484d56` (feat)
2. **Task 2: apply.rs — the helper script as a pure golden string** — `3c2e887` (feat)
3. **Task 3: apply.rs — the detached spawn and the apply entry point** — `69bcd61` (feat)

## Files Created

| File | Purpose |
|------|---------|
| `server/server-windows/src/update/marker.rs` | `marker_path`, `update_log_path`, `write_pending`(`_at`), `take_marker`(`_at`), `normalise_error`, `truncate_update_log_if_large`(`_at`), and the `MarkerFile` on-disk shape shared with the helper |
| `server/server-windows/src/update/apply.rs` | `HELPER_TEMPLATE` + pure `helper_script`, `installed_exe`, `helper_script_path`, `spawn_helper`, `begin_apply`(`_with`), and the `DETACHED_PROCESS`/`CREATE_NO_WINDOW` constants |

## Files Modified

| File | Change |
|------|--------|
| `server/server-windows/src/update/mod.rs` | `pub mod apply;` and `pub mod marker;` added to the module tree — nothing else touched |

## Key Implementation Notes

**The `set "NAME=VALUE"` idiom replaces the research example's bare `set NAME=VALUE`.** The quotes delimit the *assignment*, so they do not enter the value, and a value containing a space, an `&` or a `|` cannot terminate the command. Use sites then quote the expansion (`"%SETUP%"`). This is a strict improvement over Code Example 3 and costs nothing.

**The script is emitted with CRLF.** `cmd.exe`'s parenthesised `if (...)` block parsing is only reliably specified for CRLF batch files, and the helper has two such blocks. The rewrite is safe because every substituted value is debug-asserted newline-free first.

**`installed_exe` rebuilds from the parent directory, not from `current_exe()` itself.** They are the same path today — the installer's `DestName` renames `server-windows.exe` to `RemoteControl.exe`, so the running process already *is* `{app}\RemoteControl.exe` — but the RESEARCH Version State Inventory flags relying on that as fragile. `INSTALLED_EXE_NAME` gets a pinned-string test naming `installer/RemoteControl.iss` as the file that must change with it, on the `mutex_name_matches_the_installer_contract` template.

**`update.log` truncation was chosen, not deferred.** RESEARCH Open Question 4 offered "accept unbounded growth" or "truncate at startup above ~64 KB". The plan resolved it to the latter and it is three lines: the helper appends with `>>` from a `cmd` process with no `tracing`, so it can never join `tracing-appender`'s daily rotation, and "slowly but forever" is not a posture.

**`#![allow(dead_code)]` in `update/mod.rs` stays.** Nothing in the crate calls `begin_apply` or `take_marker` yet — the caller is 12-12's update executor / 12-10's thread wiring. The removal condition is already written next to the attribute.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Three acceptance criteria are literal greps over the whole file, including comments**

- **Found during:** Tasks 1, 2 and 3 verification
- **Issue:** The same class 12-06 hit twice. `grep -c 'env::var("APPDATA")' marker.rs == 0` returned 1 because a doc comment said *never* `std::env::var("APPDATA")`; `grep -c 'update-result.json' marker.rs == 1` returned 3 because the module header and `marker_path`'s doc both named the file beside the const; and the generated text "does not contain `timeout /t`" failed because the script's own REM comment explained why `timeout /t` is not used. `apply.rs` "contains no `.wait()` call" likewise matched a doc bullet reading "no `.wait()`".
- **Fix:** Kept every intent, removed every literal. The path comment now reads "never a raw environment-variable read (RESEARCH A5)"; the filename is stated once, in `MARKER_FILE`, with the docs pointing at the const; the script's REM says "the sleep is `ping` and deliberately NOT the timeout command"; the doc bullet says "the child is never waited on". All four criteria now pass literally, and no explanation was lost.
- **Files modified:** `server/server-windows/src/update/marker.rs`, `server/server-windows/src/update/apply.rs`
- **Commits:** `9484d56`, `3c2e887`, `69bcd61`

### Deliberate scope additions (Rule 2 — missing critical functionality)

- **The marker is validated on read.** The plan specifies parse-or-`None`. But `target` and `error` from that file flow straight into `update.status` and onto the wire, and a marker is a local file that a corrupted disk — or a local process — can shape. `is_valid_target` now gates the target, and `normalise_error` collapses anything outside the D-11 vocabulary to `installer`. Without this, an arbitrary string in the `error` field would have reached the phone, which is precisely what the closed vocabulary exists to prevent (T-12-06).
- **`take_marker` deletes before it parses.** The plan says "reads it, parses it, DELETES the file". Ordering it that way means a parse failure returns early and leaves the corrupt file behind for the next startup to trip over again. Deleting first makes "consumed exactly once" hold on every path.
- **`write_pending` debug-asserts the target too.** The plan puts the assertion in `helper_script`. But `write_pending` runs *first* in the sequence and writes the target into a file that later travels to the phone — the tripwire belongs on both entry points, matching `temp_path_for`'s precedent.
- **`helper_script` asserts the paths, not just the target.** A `"`, a newline or a `%` in a substituted path would break out of the quoting just as effectively as a bad target. None is a legal Windows path character, so an occurrence means something upstream is wrong and should fail loudly in debug.
- **A failed spawn removes the orphaned script.** The plan maps the failure to `Installer`; leaving a `.cmd` in `%TEMP%` that nothing will ever run or delete (the self-delete is the *script's* last line) is a small litter-and-forget. It is cleaned up on that path.
- **Extra tests beyond the plan's list:** the helper-written two-field success marker parsing with a trailing CRLF exactly as `cmd`'s `echo` emits it; a success marker that carries an `error` dropping it; the wait-timeout branch preceding and skipping the installer; the failure branch logging before it jumps; a failed script write leaving the marker intact; the creation-flag numeric values; and both runtime paths matching `config::config_path`'s and `config::log_dir`'s parents.

## Threat Flags

None. This plan adds no endpoint, no auth path and no wire-reachable schema. All six `mitigate` dispositions in the plan's register are discharged: T-12-01 (`begin_apply` takes a validated version and server-chosen paths only), T-12-26 (`is_valid_target` at both entry points, every value quoted, injection proven to panic), T-12-27 (the pessimistic marker precedes the helper; `verify_or_delete` remains the caller's precondition), T-12-28 (the 30-poll bound, with the timeout branch proven to skip the installer), T-12-29 (`/SUPPRESSMSGBOXES` asserted present), T-12-06 (every failure collapses to `UpdateError::Installer`; OS error kinds go to `tracing` only). T-12-30 (a local process rewriting `%TEMP%`) remains `accept` as planned, and T-12-SC holds — no new dependency.

## Known Stubs

None. Every function this plan names is implemented and tested. The module has no in-crate caller yet, which is the wave ordering the phase describes — 12-12's update executor calls `take_marker`, and the update thread calls `begin_apply` — and it is the sole reason `update/mod.rs` still carries its scoped `#![allow(dead_code)]`.

## Verification

| Check | Result |
|-------|--------|
| `cargo test -p server-windows marker` | 9 passed, 0 failed |
| `cargo test -p server-windows helper_script` | passed (incl. both `should_panic` injection cases) |
| `cargo test -p server-windows update` | 45 passed, 0 failed |
| `cargo test --workspace` | 268 passed, 0 failed, 2 ignored |
| `cargo build -p server-windows` | exit 0, no warnings |
| `grep -c 'env::var("APPDATA")' marker.rs` | 0 |
| `grep -c 'update-result.json' marker.rs` | 1 |
| `grep -c 'ping -n 2 127.0.0.1' apply.rs` | 2 (template + test) |
| `grep -c '0x0000_0008' apply.rs` / `grep -c '0x0800_0000' apply.rs` | 1 / 1 |
| `grep -c 'Stdio::null' apply.rs` | 3 |
| `grep -c '\.wait()' apply.rs` | 0 |
| Generated text contains `/SUPPRESSMSGBOXES`, not `timeout /t` | yes, asserted |
| No `__` placeholder survives substitution | yes, asserted |
| A target of `1.5.0" & calc &` produces no script containing `calc` | yes — debug assertion panics first |
| No test spawns a detached process or runs an installer | confirmed — the spawn is an injected closure in all three sequencing tests |
| Post-commit deletion check across all three commits | no deletions |

## For Future Phases

- **12-12 (the update executor)** calls `marker::take_marker()` ONCE at construction and holds the value in memory; `update.status` reports it and must not re-read the file. Call `marker::truncate_update_log_if_large()` at startup on the same path.
- **12-10 / the update thread** must call `begin_apply` only after `verify_or_delete` returned `Ok`, then publish `update.progress {stage:"restarting"}` and only *then* exit the process. `begin_apply` deliberately does not exit — that ordering is the phone's only chance to render the final stage before the socket drops.
- **`installed_exe()` and `INSTALLED_EXE_NAME` are pinned to `installer/RemoteControl.iss`'s `MyAppExeName`.** If 12-16 changes the `.iss`, check that constant.
- **The accepted gap STATE.md records still stands:** the helper's own relaunch-old-exe branch is proven only over the script *text*. 12-18 T4 exercises the phone-facing half with a hand-written marker. The cheap remedy, if ever wanted, is pointing the helper at a stub installer that exits 1.
- **`MAX_WAIT_POLLS` is 30** (~30 s at `ping -n 2`). If 12-18 observes a server that legitimately takes longer to exit, that constant is the one to move — not the `/SUPPRESSMSGBOXES` flag, which is the belt for exactly that failure.

## Self-Check: PASSED

Both created files verified present under `server/server-windows/src/update/`; all three task commits (`9484d56`, `3c2e887`, `69bcd61`) verified in `git log`; `git diff --diff-filter=D` reports no deletions on any of the three.
