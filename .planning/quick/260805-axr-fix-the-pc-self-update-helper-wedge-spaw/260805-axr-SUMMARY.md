---
quick_id: 260805-axr
phase: quick-260805-axr
plan: 01
status: complete
subsystem: server/update
tags: [windows, self-update, cmd-helper, defect-fix, test-seam]
requires:
  - server-windows update::apply (12-09)
  - server-windows update::download (12-08)
  - server-windows update::marker (12-10)
provides:
  - a helper spawned with CREATE_NO_WINDOW alone
  - a pipe-free, child-process-free exe-lock wait
  - a wait timeout that relaunches instead of abandoning the machine
  - a %TEMP% orphan sweep on the dedicated update thread
  - the first tests that actually execute spawn_helper
affects:
  - server/server-windows/src/update/apply.rs
  - server/server-windows/src/update/download.rs
  - server/server-windows/src/main.rs
tech-stack:
  added: []
  patterns:
    - "exe write-lock as the process-death signal (no tasklist, no pipe)"
    - "_in/_at/_with injectable seam for a filesystem sweep"
    - "hard-deadline real-process tests that name the defect they catch"
key-files:
  created: []
  modified:
    - server/server-windows/src/update/apply.rs
    - server/server-windows/src/update/download.rs
    - server/server-windows/src/main.rs
decisions:
  - "The pipe removal, not the creation flag, is the load-bearing half of the fix — proven by mutation testing"
metrics:
  duration: ~55 min
  completed: 2026-08-05
  tasks: 3
  commits: 3
  tests_added: 8
---

# Quick 260805-axr: Fix the PC self-update helper wedge — Summary

Repaired the `server-windows` update helper so **Update PC** can actually install:
the helper now spawns with `CREATE_NO_WINDOW` alone, waits on an exe write-lock
instead of a `tasklist | find` pipeline, relaunches the old server when the wait
times out, sweeps the `%TEMP%` files that 1.6.0/1.6.1 leaked, and — for the first
time — is executed end-to-end by two real tests.

## Commits

| Task | Commit    | What                                                        |
| ---- | --------- | ----------------------------------------------------------- |
| 1    | `fad11fe` | flags, pipe-free wait, relaunching timeout, comment rewrites |
| 2    | `e585784` | two real `spawn_helper` tests behind a hard deadline         |
| 3    | `65ddf91` | `%TEMP%` orphan sweep + step-3e wiring                       |

## Verification

| Check                                        | Result                                    |
| -------------------------------------------- | ----------------------------------------- |
| `cargo test -p server-windows`                | **123 passed**, 0 failed, 2 ignored       |
| `cargo test --workspace`                      | **green** (all 8 targets)                 |
| real-spawn tests run by default               | yes, no `--ignored`; suite finishes ~3.3 s |
| leaked processes / scratch dirs after 3 runs  | **0 / 0**                                 |
| `cargo clippy -p server-windows --all-targets` | **NOT RUN** — see Deferred                |
| `cargo build -p server-windows --all-targets`  | **0 rustc warnings** (clippy substitute)  |

## The generated `:wait` block, verbatim

Captured from `cargo test ... helper_script_text -- --nocapture` with a temporary
`println!` (since reverted; not committed). Line endings are CRLF in the real
output — the paste below shows LF because the MSYS shell capture translated them,
and `helper_script_text` asserts the CRLF property directly.

```
set /a N=0
:wait
if not exist "%EXE%" goto gone
2>nul (
  >>"%EXE%" (call )
) && goto gone
set /a N+=1
REM    Bounded (T-12-28): an exe that stays locked must not leave this helper
REM    polling forever, and firing the install into a held mutex would abort
REM    anyway. So the INSTALL is skipped on timeout - but the RELAUNCH is NOT.
REM    The shipped helper jumped straight to the cleanup label, PAST the
REM    relaunch, so a timeout for ANY reason - including a stuck lock held by
REM    something that is not the server - left the owner with no server running
REM    at all, the exact outcome this bound exists to prevent. Routing through
REM    :relaunch also reaches the cleanup label, which is what deletes the
REM    leaked setup exe on the abort path.
REM    Accepted cost: if the server really is still alive, the relaunch is
REM    refused by the single-instance mutex and the owner sees the "already
REM    running" toast. Strictly better than no server.
if %N% GEQ 30 (
  echo [%DATE% %TIME%] server exe still locked after 30 polls, pid %PID%; skipping the install and relaunching >> "%LOG%"
  goto relaunch
)
ping -n 2 127.0.0.1 >nul
goto wait
:gone
```

The whole script contains **zero `|` characters**, asserted by `helper_script_text`.

## Mutation verification (Task 2) — the plan's expectation did not hold

The plan required restoring `DETACHED_PROCESS`, observing the real-spawn test go
RED at its deadline, reverting, and observing GREEN. **The RED did not happen.**
Both outcomes are recorded verbatim below, plus the two further mutations run to
establish what actually does catch each defect.

### Mutation A — `HELPER_CREATION_FLAGS = DETACHED_PROCESS | CREATE_NO_WINDOW` (as the plan specified)

```
running 1 test
test update::apply::tests::spawn_helper_runs_the_whole_helper_to_completion ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 118 filtered out; finished in 0.32s
```

**GREEN in 0.32 s, and no stray console window appeared.** With the pipe already
removed, the flag pair alone does not wedge anything: there are no grandchild
console apps left for Windows to allocate a visible console to. The wedge required
*both* halves — no console AND a pipeline.

The same mutation IS caught, immediately and statically, by the flag test:

```
thread 'update::apply::tests::creation_flags_are_the_documented_values' panicked at
server-windows\src\update\apply.rs:1006:9:
assertion `left == right` failed: the helper is spawned with CREATE_NO_WINDOW alone
  left: 134217736
 right: 134217728
```

### Mutation B — the full shipped combination (flag pair **and** `tasklist | find` restored)

```
running 1 test
test update::apply::tests::spawn_helper_runs_the_whole_helper_to_completion ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 118 filtered out; finished in 0.82s
```

**Also GREEN, in 0.82 s.** The shipped 1.6.0/1.6.1 defect does **not** reproduce in
this harness. Under `cargo test` the parent process stays alive, and the pipeline
falls straight through to `goto gone` rather than blocking; on hardware the parent
exited immediately after the spawn, which is the condition that produced the
blocked `find`. Reproducing that faithfully would require the test to exit its own
process — out of scope, and the root cause is closed per the plan.

Mutation B is caught by the golden test instead:

```
thread 'update::apply::tests::helper_script_text' panicked at ...apply.rs:459:9:
the helper must contain NO pipe anywhere: a pipeline makes cmd re-spawn itself per
side, which is the 1.6.0/1.6.1 wedge.
```

### Mutation C — a wait that never completes (`) && goto gone` → `) && rem goto gone`)

Run to establish that the real-spawn test's deadline has teeth at all, since A and B
did not exercise it:

```
thread 'update::apply::tests::spawn_helper_runs_the_whole_helper_to_completion' panicked at
server-windows\src\update\apply.rs:758:9:
the helper never reached its self-delete within 30s. THIS IS THE 1.6.0/1.6.1 WEDGE:
check the creation flags (DETACHED_PROCESS must NOT be set) and that the script
contains no pipe. A stray console window on the desktop is the same symptom.

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 118 filtered out; finished in 30.08s
```

**RED at the deadline, with the self-diagnosing message.** This is the failure mode
the test exists for: the helper does not complete.

### Post-revert GREEN

Both mutations reverted, full module suite:

```
running 15 tests
...
test update::apply::tests::spawn_helper_runs_the_whole_helper_to_completion ... ok
test update::apply::tests::spawn_helper_waits_while_the_exe_is_locked ... ok

test result: ok. 15 passed; 0 failed; 0 ignored; 0 measured; 104 filtered out; finished in 3.24s
```

### A fourth, unplanned RED — the test caught a real bug on its first run

Before any deliberate mutation, the two new tests failed for real: the fixture
reused `scratch_dir`, which rendered `ThreadId(13)` into the path, and
`Command::args` does not quote a space-free argument, so `cmd /c C:\...ThreadId(13)\...`
ended at the paren and the helper never ran. The failure message was exactly the
intended diagnostic, and the leftover scratch dir showed the signature of a helper
that never reached a logging branch — no `update.log`, setup exe intact — which is
the shipped defect's own signature. That is the strongest evidence available that
this test detects "the helper did not run".

**Conclusion recorded as a decision:** the pipe removal is the load-bearing half of
this fix; the creation flag is defence in depth, pinned statically rather than
behaviourally. The plan's assumption that the flag alone would turn the real-spawn
test red was wrong, and the objection is recorded here rather than acted on — D-A
was implemented exactly as written.

### Cleanup

No wedged `cmd.exe` and no scratch directory remain. Nine lingering
`cmd.exe /K ...stub-exe.cmd` processes accumulated during development (see
Deviations) and were killed by PID; three consecutive full runs afterwards left
**0 processes and 0 scratch directories**, verified by `Win32_Process` query and
directory listing.

## Sweep: `MIN_ORPHAN_AGE` and this machine's real orphans

`MIN_ORPHAN_AGE = Duration::from_secs(60 * 60)` — **1 hour**.

The server binary was **not run**, so there is no first-real-startup count to
report. What can be reported is better: the actual orphans from the 12-18 Task 4
hardware wedge are still sitting in this machine's `%TEMP%` right now —

```
-rwxr-xr-x  5898789  Aug  5 07:31  RemoteControl-Setup-v1.6.1.exe
-rw-r--r--     3154  Aug  5 07:31  rc-update-7556.cmd
```

— the exact byte size (5,898,789) and the exact PID (7556) recorded in the defect
note. Both are now more than an hour old, so the next real startup will sweep
**2** files and log `update: removed 2 stale update file(s) from the temp directory`.
They were deliberately left in place as evidence rather than deleted by hand.

## Deviations from Plan

### 1. [Rule 1 — Bug] `the_success_rewrite_is_unreachable_from_the_failure_path` resolved the wrong jump

- **Found during:** Task 1
- **Issue:** Making the timeout branch `goto relaunch` created a SECOND
  `goto relaunch` in the script, earlier than the failure branch's. The test took
  `s.find("goto relaunch")` — the first occurrence — so its `log_line < jump`
  assertion failed.
- **Fix:** the failure branch's jump is now located from its own log line
  (`setup exited %ERRORLEVEL%`) rather than by taking the first match. The
  assertion's meaning is unchanged and its strength is unchanged.
- **Commit:** `fad11fe`

### 2. [Rule 3 — Blocking] `scratch_dir` produced a path `cmd` could not accept

- **Found during:** Task 2
- **Issue:** the plan says to reuse `scratch_dir` verbatim, but it renders
  `ThreadId(13)` and `Command` does not quote a space-free argument, so the real
  spawn never ran. Both new tests failed at their deadline.
- **Fix:** `scratch_dir` now renders the thread id digits-only, with the reason
  documented. Still ONE scratch convention, which is what the plan's instruction
  was protecting.
- **Commit:** `e585784` · **Also logged to** `deferred-items.md` (the production-side
  residual is untouched)

### 3. [Rule 1 — Bug] The relaunch stub stranded a `cmd /K` per test run

- **Found during:** Task 2
- **Issue:** `start` launches a batch target through `cmd /K`, which keeps the
  process and its console window alive after the script ends. Nine lingering
  `cmd.exe` processes accumulated, each holding a scratch directory open so the
  tests' own cleanup silently failed — the plan predicted only a brief flash. This
  also explains a 7-minute apparent hang of the test command: the lingering
  processes held the shell's pipe open long after the suite had finished in 3 s.
- **Fix:** the stub ends with a bare `exit`, on the SAME LINE as its write (`cmd`
  re-opens a batch file per line, so an `exit` on its own line is lost when the
  directory is removed the moment `relaunched.txt` appears). Both tests now wait
  for the relaunch before cleaning up — which also strengthens test 2, since it now
  asserts the relaunch fires on the wait-then-release path too.
- **Commit:** `e585784`

### 4. [Deviation from plan text] The timeout log line uses `pid %PID%`, not `(pid %PID%)`

- **Found during:** Task 1
- **Issue:** the plan sketched the log line with parentheses around the pid. That
  line sits inside an `if (...)` block, where `cmd` counts unquoted parentheses
  while parsing the block.
- **Fix:** the parentheses are dropped; the line is otherwise the plan's shape.
  The plan said "something of the shape", so this is within its latitude.
- **Commit:** `fad11fe`

### 5. [Objection recorded, not acted on] The mutation the plan mandated does not go red

See the mutation section above. D-A was implemented exactly as written; the
objection is recorded rather than substituted.

## Deferred (not fixed here)

Written to `deferred-items.md` in this directory:

1. **`cargo clippy` cannot run** — `server/rust-toolchain.toml` pins 1.97.0 and the
   clippy component exists only for 1.89; `cargo +1.89 clippy` fails because
   `egui 0.35` requires rustc 1.92. Pre-existing; remedy is a toolchain component
   download this plan is not authorised to perform. Substitute: a full
   `--all-targets` build produced 0 rustc warnings.
2. **`spawn_helper` passes the script path to `cmd /c` unquoted** — narrow residual
   risk for a `%TEMP%` containing `(`, `)` or `&` and no space. Deserves its own
   task; `cmd /c` quote-stripping is subtle enough not to change in passing.

## Known Stubs

None. `stub-exe.cmd` and `stub-setup.exe` are test fixtures under `#[cfg(test)]`,
not production placeholders.

## Threat Flags

None. No new network endpoint, auth path or schema. The one new file-system writer
(`sweep_temp_orphans_in`) is covered by T-AXR-03 in the plan's register and is
implemented as specified: both-ends-anchored matcher built from the writers' own
constants, files only, own-script skip, age guard, `e.kind()` at debug on failure,
and a log line carrying a count and never a path.

## DELIVERY IS NOT DONE

**This plan made the code correct. It shipped nothing.**

The broken helper is inside **both `1.6.0` and `1.6.1`**, so the fix cannot travel
through the path it repairs — every installed client would wedge on the way to
receiving it. Before 12-18 Task 4 can be re-run:

1. build `1.6.2` and install it **BY HAND** (Inno setup exe via
   `installer/build-installer.ps1`);
2. publish `1.6.3` as the tap target;
3. only then re-run 12-18 Task 4 and re-check SC5 and SC7.

No version was bumped, no tag created, no release published, and
`tools/release.ps1`, `installer/RemoteControl.iss` and
`installer/build-installer.ps1` were not touched. **Phase 12's SC5 remains unmet
until that hand-delivery happens.**

## Self-Check: PASSED

Files verified present on disk:

- `server/server-windows/src/update/apply.rs` — FOUND (contains
  `HELPER_CREATION_FLAGS`, `sweep_temp_orphans_in`)
- `server/server-windows/src/update/download.rs` — FOUND (contains
  `pub(super) const SETUP_FILE_PREFIX`)
- `server/server-windows/src/main.rs` — FOUND (contains `sweep_temp_orphans()`)
- `.planning/quick/260805-axr-fix-the-pc-self-update-helper-wedge-spaw/deferred-items.md` — FOUND

Commits verified in `git log`:

- `fad11fe` — FOUND
- `e585784` — FOUND
- `65ddf91` — FOUND

Working tree clean apart from this planning directory.
