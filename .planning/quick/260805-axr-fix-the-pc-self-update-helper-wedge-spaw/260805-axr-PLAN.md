---
quick_id: 260805-axr
phase: quick-260805-axr
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - server/server-windows/src/update/apply.rs
  - server/server-windows/src/update/download.rs
  - server/server-windows/src/main.rs
autonomous: true
requirements:
  - DEFECT-2026-08-05-pc-self-update-helper-wedges
user_setup: []

must_haves:
  truths:
    - "The spawned helper carries CREATE_NO_WINDOW and NOT DETACHED_PROCESS"
    - "The generated helper script contains no pipe character at all"
    - "A wait timeout skips the installer but still relaunches the old server"
    - "spawn_helper is executed by a real test that asserts its outcome on disk"
    - "A previous attempt's leaked %TEMP% script and setup exe are removed at startup"
    - "cargo test -p server-windows passes; cargo test --workspace still passes"
  artifacts:
    - path: "server/server-windows/src/update/apply.rs"
      provides: "corrected spawn flags, pipe-free wait, relaunching timeout, %TEMP% sweep, real spawn tests"
      contains: "HELPER_CREATION_FLAGS"
    - path: "server/server-windows/src/update/download.rs"
      provides: "SETUP_FILE_PREFIX/SUFFIX visible to the sweep so the match cannot drift"
      contains: "pub(super) const SETUP_FILE_PREFIX"
    - path: "server/server-windows/src/main.rs"
      provides: "the startup sweep wired at step 3e, off the startup critical path"
      contains: "sweep_temp_orphans"
  key_links:
    - from: "server/server-windows/src/update/apply.rs::spawn_helper"
      to: "HELPER_CREATION_FLAGS"
      via: "creation_flags"
      pattern: "creation_flags\\(HELPER_CREATION_FLAGS\\)"
    - from: "server/server-windows/src/update/apply.rs::sweep_temp_orphans_in"
      to: "download::SETUP_FILE_PREFIX"
      via: "filename match built from the writer's own constants"
      pattern: "download::SETUP_FILE_PREFIX"
    - from: "server/server-windows/src/main.rs step 3e"
      to: "update::apply::sweep_temp_orphans"
      via: "first statement on the dedicated update thread"
      pattern: "sweep_temp_orphans\\(\\)"
---

<objective>
Repair the PC self-update helper so that tapping **Update PC** actually installs
and the server comes back.

Five changes, all inside `server-windows`:

1. spawn the helper with `CREATE_NO_WINDOW` **alone** — `DETACHED_PROCESS`
   makes Windows ignore it, which is what left the child with no console and
   wedged `find` on its pipe;
2. remove the pipe from the wait loop entirely, replacing `tasklist | find`
   with a zero-child-process exe-lock test;
3. make the wait timeout relaunch the old server instead of jumping past the
   relaunch (a second, previously unrecorded defect);
4. sweep the `%TEMP%` files that 1.6.0/1.6.1 already leak on every wedged
   attempt (a `.cmd` plus a ~5.9 MB setup exe);
5. close the untested seam: a REAL test that executes `spawn_helper` and
   asserts the helper's outcome on disk.

Purpose: `1.6.0` and `1.6.1` both ship a self-updater that exits the server and
never brings it back. Phase 12's SC5 is unmet and SC7 is unreachable until this
lands.

Output: a corrected `update::apply`, a startup sweep, and the test that would
have caught the shipped bug.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
</execution_context>

<context>
@.planning/todos/pending/2026-08-05-pc-self-update-helper-wedges-before-setup-runs.md
@server/server-windows/src/update/apply.rs
@server/server-windows/src/update/download.rs
@server/server-windows/src/update/marker.rs
@server/server-windows/src/main.rs
@installer/RemoteControl.iss
</context>

<already_established>
**Do NOT re-investigate any of this. It was checked directly on real hardware.**

- **Root cause.** `spawn_helper` (`apply.rs:260`) passes
  `.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW)`. Per MS "Process
  Creation Flags", `CREATE_NO_WINDOW` is **ignored** when `DETACHED_PROCESS` is
  set, so the child `cmd.exe` has NO console. Its
  `tasklist /FI "PID eq %PID%" /NH 2>nul | find "%PID%"` pipeline makes cmd
  re-spawn itself twice; the console-app grandchildren then have Windows
  allocate them fresh, VISIBLE consoles (the observed window titled
  `find "7556"`), and `find` blocks on its pipe. Measured **0.03125 s CPU across
  4+ minutes** — blocked, not spinning — so not one poll ever completed and the
  `MAX_WAIT_POLLS = 30` bound never armed.
- **Ruled out, do not touch:** the batch wait logic itself (run by hand against
  the dead PID, it correctly falls to `goto gone`), script generation (every
  placeholder substituted, `__MAX_POLLS__` → `30`, CRLF correct), the
  download/verification, the marker protocol, and the single-instance mutex
  (`CreateMutexW(None, ...)` ⇒ non-inheritable handle, so the helper does not
  keep the `AppMutex` alive).
- **Second defect, not in the todo.** In `HELPER_TEMPLATE` the wait-timeout
  branch does `goto end`, and `:end` sits AFTER `start "" "%EXE%"` at
  `:relaunch`. A timeout therefore skips the relaunch too, leaving the owner
  with no server running — the exact outcome the bound exists to prevent.
  Compare `apply.rs:114-119` against `apply.rs:139-146`.
</already_established>

<decisions_the_executor_must_not_relitigate>

**D-A — Drop `DETACHED_PROCESS`, keep `CREATE_NO_WINDOW`.**
Helper survival does not depend on `DETACHED_PROCESS`: Windows has no
parent-child lifetime link and `std::process::Child` has no kill-on-drop, which
is what the existing `spawn_helper` doc comment already says. `CREATE_NO_WINDOW`
alone gives the child its **own, never-displayed** console, so console-app
grandchildren inherit it instead of having a visible one allocated for them.
The `DETACHED_PROCESS` constant STAYS in the file — renamed in its
documentation as the flag that must never be used again — so the new test can
assert its absence and a future reader meets the explanation before the flag.

**D-B — The wait becomes an exe-lock test, not a redirected `tasklist`.**
Two candidates were considered:
- (a) `>>"%EXE%" (call )` inside a `2>nul` block — **CHOSEN**. Zero child
  processes, zero pipes, zero consoles, nothing to clean up. And it tests
  exactly what Setup needs: that `{app}\RemoteControl.exe` is replaceable. A
  running process always holds a write lock on its own image (Windows shares
  only READ and DELETE on a mapped image), so "the exe is writable" implies
  "that server process is dead", which implies the `AppMutex` kernel object is
  released. It is therefore at least as strong a gate as PID death, and
  strictly stronger against a third party holding the file.
- (b) `tasklist` redirected to a file, then `findstr`. Rejected: two child
  processes, a second temp file to create and clean up, and a slower poll — all
  to re-derive a weaker signal.

`%PID%` is KEPT in the script as the diagnostic anchor for the timeout log line
(and the script filename is already per-PID), so `helper_script`'s signature does
not change and the golden test's `set "PID=4242"` assertion stands.

**D-C — The timeout relaunches.** Accepted trade-off: if the wait times out
because the server really is still alive, the relaunch starts a second instance,
the single-instance mutex refuses it, and the owner sees the "already running"
toast. That is strictly better than the current behaviour, where a timeout for
ANY reason — including a stuck lock held by something that is not the server —
leaves the owner with no server at all. Routing the timeout through `:relaunch`
also routes it through `:end`, which is what finally deletes the leaked setup
exe on the abort path.

**D-D — The real spawn test asserts the NON-ZERO installer branch, not the
`ok:true` promotion.** This is a deliberate, documented deviation, not an
oversight. The helper invokes `"%SETUP%" /VERYSILENT ...` with no `call`, so a
`.cmd` stub would CHAIN and never return — the helper's remaining lines would
not run. A real PE is therefore required, and no stock Windows console exe exits
**0** when handed `/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG=...` (they all
reject the unknown switch non-zero). Committing a hand-built PE or shelling out
to `csc.exe` costs more than it buys. The failure branch exercises every single
thing the wedge broke — the wait completing, Setup being INVOKED, the D-24 log
line, the relaunch, and both deletions — and it additionally closes the ONE
ACCEPTED GAP recorded in STATE.md ("the helper's own relaunch-old-exe behavior
is never run. Cheap remedy if wanted: point the helper at a stub installer that
exits 1"). The `ok:true` rewrite itself stays covered by the golden text test
plus `marker.rs::helper_written_success_marker_parses_without_an_error_field`,
which parses the exact bytes the `echo` emits.

**D-E — The real spawn tests run by DEFAULT (no `#[ignore]`), and carry a hard
deadline.** An ignored test is a test that never runs, and this is the one test
that would have caught a shipped defect. The deadline is what makes it safe to
run by default: if the helper ever wedges again the test FAILS at the deadline
instead of hanging the suite. `#[cfg(windows)]` is omitted as decorative — this
file's `use std::os::windows::process::CommandExt` already means the crate
cannot compile anywhere else.
</decisions_the_executor_must_not_relitigate>

<out_of_scope>
**Do NOT do any of these. Delivery is a separate follow-up.**

- Do NOT bump the version in any `Cargo.toml` or `pubspec.yaml`.
- Do NOT publish a release, tag anything, or run `tools/release.ps1`.
- Do NOT touch `tools/release.ps1`, `installer/RemoteControl.iss`, or
  `installer/build-installer.ps1`.
- Do NOT touch anything under `app/` (Flutter), `extension/`, `protocol/`, or
  `server/server-core/`.

**Why:** the fix cannot ship through the path it repairs. The broken helper is
inside both `1.6.0` and `1.6.1`, so re-running 12-18 Task 4 needs `1.6.2`
installed **by hand** and `1.6.3` as the tap target. That delivery is its own
follow-up task; this plan only makes the code correct.

**Also unchanged — do not "improve" these while in the file:**
- the `^\d+\.\d+\.\d+$` target validation and its debug tripwires;
- the closed D-11 error vocabulary reaching the wire (no paths, codes or OS
  strings — keep logging `e.kind()`, never a path);
- D-16 pessimistic-marker-before-spawn ordering inside `begin_apply_with`;
- `/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG=` on the setup invocation;
- the `set "NAME=VALUE"` quoting idiom and the CRLF rewrite;
- `MAX_WAIT_POLLS = 30` and the `ping -n 2 127.0.0.1` sleep.
</out_of_scope>

<house_style>
This module documents WHY at unusual density and its tests assert design
decisions, not just behaviour. Match that:

- Every comment that currently explains the `DETACHED_PROCESS` choice is now
  WRONG. Rewrite it to explain the corrected choice **and why the old pair
  wedged**, so a future reader cannot re-add the flag in good faith. Deleting
  those comments is not acceptable; correcting them is.
- New tests get a doc comment saying what design decision they pin.
- Log `e.kind()` and counts, never paths.
- Failure posture stays DEGRADE, NEVER CRASH: no new `unwrap`, `expect` or
  `panic!` outside `#[cfg(test)]`.
</house_style>

<tasks>

<task type="auto">
  <name>Task 1: Fix the spawn flags, remove the pipe, make the timeout relaunch</name>
  <files>server/server-windows/src/update/apply.rs</files>
  <read_first>
    Already in context. `apply.rs:44-51` (the flag constants), `apply.rs:1-15`
    (module doc), `apply.rs:82-151` (`HELPER_TEMPLATE`), `apply.rs:248-269`
    (`spawn_helper`), `apply.rs:364-460` (the three golden tests),
    `apply.rs:681-685` (`creation_flags_are_the_documented_values`).
  </read_first>
  <action>
Four edits in one file, one commit.

**1a. The creation flags (`apply.rs:44-51` and `spawn_helper`).**
Introduce `const HELPER_CREATION_FLAGS: u32 = CREATE_NO_WINDOW;` and have
`spawn_helper` pass `.creation_flags(HELPER_CREATION_FLAGS)`. Keep
`CREATE_NO_WINDOW` documented as the MS value it is. KEEP the
`DETACHED_PROCESS` constant but rewrite its doc comment to say, in this order:
that it is **deliberately not used**; that MS "Process Creation Flags"
specifies `CREATE_NO_WINDOW` is IGNORED when `DETACHED_PROCESS` is set; that
the pair therefore left the child with no console at all, which made cmd's
`tasklist | find` pipeline allocate fresh VISIBLE consoles for its
grandchildren and block `find` on its pipe read (observed on hardware, 12-18
Task 4: 0.03 s CPU across four minutes, a window titled `find "7556"`, Setup
never run); and that helper survival never depended on it, because Windows has
no parent-child lifetime link and `std::process::Child` has no kill-on-drop.
Rewrite the `spawn_helper` doc comment's "Three deliberate choices" list the
same way — the first bullet currently states the wrong reason for the right
outcome. Keep the null stdio bullet and the never-waited-on bullet as they are:
both are still true and still load-bearing.

Also fix the module doc comment at `apply.rs:11-15`, which names the flag pair
in prose.

**1b. The wait loop in `HELPER_TEMPLATE`.**
Replace the single `tasklist ... | find ... || goto gone` line with a pipe-free,
child-process-free exe-lock test, per D-B. Emit exactly these two constructs at
the top of the `:wait` body, in this order:

  - `if not exist "%EXE%" goto gone` — a guard, not an optimisation: `>>` on a
    missing file CREATES it, and `installed_exe()` degrades to the bare name
    `RemoteControl.exe` when `current_exe()` fails, which would otherwise mean
    conjuring a stray file into the helper's working directory. If the exe is
    genuinely absent there is nothing to wait for and nothing to protect.
  - the lock test itself, written in the canonical multi-line form so it matches
    the idiom exactly: a line `2>nul (`, then a line whose trimmed content is
    `>>"%EXE%" (call )`, then a line `) && goto gone`. `(call )` — with the
    space — is the no-op that sets ERRORLEVEL 0, so `&&` fires only when the
    append redirection itself succeeded. A running process holds a write lock on
    its own image, so a successful append means that server is gone.

Everything else in the loop stays: `set /a N=0` before `:wait`, `set /a N+=1`,
the `if %N% GEQ __MAX_POLLS__` block, `ping -n 2 127.0.0.1 >nul`, `goto wait`,
`:gone`.

Rewrite the REM block above the loop (currently `apply.rs:102-105`) to explain:
what is being waited on and why (the exe write-lock is released by the same
process death that releases the `AppMutex` Setup checks, and it additionally
covers a third party holding the file); that the check is deliberately
PIPE-FREE and spawns no child process, because a pipe is what wedged the
shipped 1.6.0/1.6.1 helper; and that the sleep is `ping` and not `timeout`
because `timeout` reads stdin and this child's stdin is `NUL`.

**1c. The timeout branch must relaunch (`apply.rs:114-119`).**
Change its `goto end` to `goto relaunch`, and rewrite both the log line and the
REM above it. The log line keeps `%PID%` as the diagnostic anchor and now
describes what actually happened and what is being done about it — something of
the shape `[%DATE% %TIME%] server exe still locked after __MAX_POLLS__ polls
(pid %PID%); skipping the install and relaunching`. The REM must record the
D-C trade-off: the install is skipped because firing it into a held mutex would
abort anyway, but the relaunch is NOT skipped, because a timeout with the
server actually dead would otherwise leave the owner with no server at all —
and routing through `:relaunch` also reaches `:end`, which is what deletes the
leaked setup exe on the abort path. Note the accepted cost: if the server
really is alive, the relaunch is refused by the single-instance mutex and the
owner sees the "already running" toast.

**1d. Update the three affected tests.**
  - `helper_script_text`: replace `assert!(s.contains("tasklist /FI"))` with a
    hard pipe assertion — `assert!(!s.contains('|'), ...)` — plus positive
    assertions for `if not exist "%EXE%" goto gone`, `>>"%EXE%" (call )` and
    `) && goto gone`. **Hazard:** the no-pipe assertion is self-invalidating if
    any REM comment inside `HELPER_TEMPLATE` contains a `|` character; make
    sure none does. Keep the `!s.contains("timeout /t")` assertion but rewrite
    its message: `timeout` fails because it reads stdin and this child's stdin
    is `NUL`, not because the child has no console.
  - `the_wait_timeout_skips_the_installer_entirely`: rename to
    `the_wait_timeout_skips_the_installer_but_still_relaunches` and assert BOTH
    halves — the timeout log line still precedes the `"%SETUP%" /VERYSILENT`
    call, AND the timeout's jump target is `relaunch` so the relaunch is
    reached. Add `assert!(!s.contains("goto end"), ...)` as the regression pin
    with a message naming this defect: nothing may ever jump past the relaunch
    again. `:end` itself stays and is asserted to sit after
    `start "" "%EXE%"`.
  - `creation_flags_are_the_documented_values`: keep the two MS value
    assertions (`DETACHED_PROCESS == 8`, `CREATE_NO_WINDOW == 134_217_728`) and
    add the two that matter — `HELPER_CREATION_FLAGS == CREATE_NO_WINDOW`, and
    `HELPER_CREATION_FLAGS & DETACHED_PROCESS == 0` with a message stating that
    the two flags are not a valid pair and that this is the shipped 1.6.0/1.6.1
    defect.

Finally re-run `an_accepted_target_introduces_no_command_separator`: it asserts
exactly one occurrence of `" & "` (space-ampersand-space). The new `") && goto
gone"` does not contain that substring, so the count must stay 1 — if it does
not, something else changed and must be understood, not silenced.
  </action>
  <verify>
    <automated>cd server && cargo test -p server-windows update::apply</automated>
  </verify>
  <done>
    `cargo test -p server-windows update::apply` passes. `spawn_helper` calls
    `.creation_flags(HELPER_CREATION_FLAGS)` and `HELPER_CREATION_FLAGS` does
    not include `DETACHED_PROCESS`. The generated script contains no `|`
    anywhere. The timeout branch jumps to `relaunch` and no `goto end` remains.
    Every comment that previously justified `DETACHED_PROCESS` now explains the
    corrected choice and the wedge.
  </done>
</task>

<task type="auto">
  <name>Task 2: Execute spawn_helper for real and assert its outcome on disk</name>
  <files>server/server-windows/src/update/apply.rs</files>
  <read_first>
    `apply.rs`'s existing `scratch_dir` test helper (`apply.rs:517-527`) — reuse
    it verbatim rather than inventing a second scratch convention.
  </read_first>
  <action>
Add two tests to `apply.rs`'s `mod tests`. Both call the REAL `spawn_helper`
against a REAL generated script. This is the seam the shipped bug lived behind
— `spawn_helper` is currently the one function in this path no test executes.

**Shared fixture (a small helper fn in `mod tests`).** Under a `scratch_dir`:
  - `stub-exe.cmd` — the relaunch target. `start "" "%EXE%"` uses ShellExecute
    semantics and always SPAWNS, so a `.cmd` is fine here (unlike the setup
    invocation). Its body writes a `relaunched.txt` beside itself. Document in
    the doc comment that this briefly flashes a console window when it fires,
    and that that is the honest price of covering the seam.
  - `stub-setup.exe` — a file that is deliberately NOT a valid PE (a few bytes
    of text). `cmd` cannot execute it, so `if errorlevel 1` fires
    deterministically. See D-D for why the zero-exit branch is not covered here.
  - the pessimistic marker, written with `marker::write_pending_at`, so the test
    starts from the exact state `begin_apply_with` leaves behind.
  - an `update.log` path (not pre-created).
  - the script at `<scratch>/rc-update-test.cmd`, written from
    `helper_script(pid, setup, exe, marker, log, "1.6.0")` — the REAL generator,
    not a hand-written script.
  - `pid`: use `std::process::id()`. It is irrelevant to the wait now (the wait
    is the exe lock) and only reaches the timeout log line; say so in a comment
    so a reader does not think the test is waiting on itself.

**Test 1 — `spawn_helper_runs_the_whole_helper_to_completion`.**
Nothing holds a lock on `stub-exe.cmd`, so the first poll's append succeeds and
the helper falls straight to `:gone`. Spawn, then poll on a HARD DEADLINE (≤ 30 s
in 100 ms steps) for the script to self-delete. Assert, after it does:
  - the script is gone (`(goto) 2>nul & del "%~f0"` ran — the helper reached its
    last line);
  - `stub-setup.exe` is gone (`del "%SETUP%"` at `:end` ran);
  - `update.log` exists and contains `setup exited` — Setup was actually
    INVOKED, which is the single thing the wedge prevented;
  - the marker still reads `"ok":false` — the promotion is correctly unreachable
    from the failure path (D-24);
  - `relaunched.txt` exists — the relaunch fired. Poll for this on its own short
    deadline, since `start` returns before the spawned stub has written.
On deadline expiry, fail with a message that names the wedge explicitly, so a
future failure is self-diagnosing rather than a mystery timeout.

**Test 2 — `spawn_helper_waits_while_the_exe_is_locked`.**
The regression test for the wait itself. Open `stub-exe.cmd` with
`std::fs::OpenOptions` plus `std::os::windows::fs::OpenOptionsExt::share_mode(0)`
and `.write(true)`, holding the handle — that denies all sharing, so the
helper's append fails exactly as it does against a running server's image.
Then:
  1. spawn the helper;
  2. sleep ~2.5 s (two-plus poll intervals) and assert the helper has NOT
     progressed: `update.log` does not exist (or carries no `setup exited`),
     `stub-setup.exe` still exists, and the script still exists;
  3. drop the file handle;
  4. poll on the same hard deadline for the script to self-delete, then assert
     `update.log` now carries `setup exited` — the wait released and the helper
     completed.
This proves the loop actually loops, which the golden text test cannot.

Both tests remove their scratch directory at the end. Neither is `#[ignore]`d
and neither is `#[cfg(windows)]`-gated — see D-E.

**Mutation verification (REQUIRED — record the result in the summary).**
This repo proves its tests have teeth rather than assuming it (the 11-02
`reset_relay_watches` precedent). Temporarily change `HELPER_CREATION_FLAGS`
back to `DETACHED_PROCESS | CREATE_NO_WINDOW`, run ONLY test 1
(`cd server && cargo test -p server-windows spawn_helper_runs_the_whole_helper_to_completion -- --exact --nocapture`),
and observe it FAIL at the deadline — with a stray console window appearing,
which is the shipped defect reproduced on demand. Then revert the constant and
re-run to GREEN. Record both outcomes verbatim in the summary. Clean up the
wedged helper afterwards: it is a `cmd.exe` whose command line names the scratch
script; find it in Task Manager (Details → Command line) or with
`Get-CimInstance Win32_Process -Filter "Name='cmd.exe'"` and end it, then delete
the leftover scratch directory.
  </action>
  <verify>
    <automated>cd server && cargo test -p server-windows update::apply -- --nocapture</automated>
  </verify>
  <done>
    Both real-spawn tests pass by default (no `--ignored` needed) in under ~40 s
    combined. The mutation verification has been run and both outcomes — RED
    with `DETACHED_PROCESS` restored, GREEN without it — are recorded verbatim
    in the summary. No wedged `cmd.exe` and no scratch directory are left
    behind.
  </done>
</task>

<task type="auto">
  <name>Task 3: Sweep the %TEMP% files leaked by 1.6.0/1.6.1 at startup</name>
  <files>server/server-windows/src/update/apply.rs, server/server-windows/src/update/download.rs, server/server-windows/src/main.rs</files>
  <read_first>
    `download.rs:36-39` (`SETUP_FILE_PREFIX` / `SETUP_FILE_SUFFIX`) and
    `download.rs:91-98` (`temp_path_for`) — the sweep's match MUST be built from
    the writer's own constants, never a re-typed literal. `apply.rs:238-246`
    (`helper_script_path`). `main.rs:198-206` (step 3e, where the update thread
    is spawned).
  </read_first>
  <action>
A wedged attempt leaks `%TEMP%\rc-update-<pid>.cmd` plus a ~5.9 MB
`%TEMP%\RemoteControl-Setup-v<x.y.z>.exe`, once per attempt, because `del` and
the self-delete both sit at `:end` which a wedged run never reaches. Every
machine running 1.6.0/1.6.1 already carries orphans, and Task 1's fix does not
retroactively remove them.

**3a. `download.rs`** — change `SETUP_FILE_PREFIX` and `SETUP_FILE_SUFFIX` to
`pub(super)`, with a one-line comment saying the sweep in `apply` matches on
them so the matcher cannot drift from `temp_path_for`. Change nothing else in
this file.

**3b. `apply.rs`** — factor the helper script's name out of
`helper_script_path()` into `HELPER_SCRIPT_PREFIX` (`"rc-update-"`) and
`HELPER_SCRIPT_SUFFIX` (`".cmd"`) and rebuild the path from them, for the same
anti-drift reason. Then add:

  - `const MIN_ORPHAN_AGE: Duration` = 1 hour. Document the choice: the only
    thing an age guard protects against is a helper from a PREVIOUS process that
    is still counting down its bounded wait, which cannot exceed ~30 s, so an
    hour is generous; and the leftovers this exists to clear are hours or days
    old. Nothing in the CURRENT process can be at risk — the sweep runs once at
    startup, and this process's own script and setup exe are not created until
    the owner asks for an update, long afterwards.
  - `pub fn sweep_temp_orphans()` — the production entry point, calling the seam
    below with `std::env::temp_dir()`, `helper_script_path()` and
    `MIN_ORPHAN_AGE`.
  - `fn sweep_temp_orphans_in(dir: &Path, own_script: &Path, min_age: Duration)
    -> u32` — the injectable seam, matching this module's existing `_at` / `_with`
    convention (`write_pending_at`, `take_marker_at`, `begin_apply_with`).
    Returns the count removed so both the log line and the tests can assert it.
    Behaviour:
      * `read_dir` failure ⇒ log `e.kind()` at debug and return 0. Never a warn,
        never a panic — an unsweepable `%TEMP%` is not a reason to do anything
        differently (the `truncate_update_log_if_large` posture).
      * A candidate is a FILE whose name either starts with
        `HELPER_SCRIPT_PREFIX` and ends with `HELPER_SCRIPT_SUFFIX`, or starts
        with `download::SETUP_FILE_PREFIX` and ends with
        `download::SETUP_FILE_SUFFIX`. Directories are never touched.
      * **Never delete this process's own file:** skip any entry whose
        `file_name()` equals `own_script.file_name()`. This is the PID guard,
        expressed against the writer's own path rather than by re-deriving the
        PID.
      * Age guard: skip unless `now - modified >= min_age`. An unreadable
        `modified()`, or a timestamp in the future, is treated as FRESH and
        skipped — the safe direction.
      * `remove_file` failure ⇒ log `e.kind()` at debug and continue. A file
        another process still holds open simply stays; the next startup gets it.
      * Log once at info with the COUNT only, and only when the count is
        non-zero. Counts and error kinds, never paths.

  Tests (same `scratch_dir` helper, injected directory — the real `%TEMP%` is
  never swept by a test):
      1. a foreign-PID script (`rc-update-999999.cmd`) and a setup exe are both
         removed with `Duration::ZERO`;
      2. this process's own script name survives even at `Duration::ZERO` — the
         load-bearing safety assertion;
      3. unrelated neighbours are untouched: a plain `.txt`, a bare `.cmd` with
         no prefix, a `RemoteControl-Setup-v1.2.3.exe.part`, and a
         subdirectory named like a candidate;
      4. a freshly-created orphan survives `MIN_ORPHAN_AGE`;
      5. a missing directory returns 0 and does not panic;
      6. the anti-drift pin: the file name produced by
         `download::temp_path_for("1.2.3")` and by `helper_script_path()` are
         each matched by the sweep's own predicate. This is the test that fails
         if someone renames a constant on one side only.

**3c. `main.rs`, step 3e** — call `update::apply::sweep_temp_orphans()` as the
FIRST statement inside the closure already passed to `std::thread::spawn` at
`main.rs:205`, before `update_thread::run_update_thread(...)`. Add a comment in
the step-3e block's existing style explaining why it lives exactly there: a
`read_dir` over `%TEMP%` is unbounded work and must never sit between process
start and the input thread this app exists to keep instant; the update thread is
already dedicated, already spawned before the listener binds, and then blocks on
`recv()` doing nothing — so the sweep is free there. Nothing has asked for an
update yet, so there is nothing to race. Do not move it into `WinUpdate::new`
(that runs on the main async task, ahead of the bind) and do not spawn a
thread of its own for it.
  </action>
  <verify>
    <automated>cd server && cargo test -p server-windows && cargo test --workspace</automated>
  </verify>
  <done>
    `cargo test --workspace` passes. `sweep_temp_orphans_in` removes a foreign
    orphan script and a stale setup exe, never removes this process's own
    script, never removes a fresh file, never touches a non-candidate, and never
    panics on a missing directory. `main.rs` step 3e calls
    `update::apply::sweep_temp_orphans()` as the update thread's first act, with
    the reason written down.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| phone → `update.apply` | the only wire-influenced value is `target`, matched against `^\d+\.\d+\.\d+$` before ANY use — unchanged by this plan |
| server → generated `.cmd` | every value interpolated into a command line the OS will execute with the owner's privileges |
| `%TEMP%` → the sweep | a local directory any local process can write into |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-AXR-01 | Elevation of Privilege | `helper_script` interpolation | mitigate | UNCHANGED: the `^\d+\.\d+\.\d+$` validation, the `debug_assert!` tripwires, the path metacharacter assertions and the `set "NAME=VALUE"` idiom all stay exactly as they are. The plan adds no new interpolation site. `an_accepted_target_introduces_no_command_separator` still pins the single `" & "`. |
| T-AXR-02 | Tampering | `>>"%EXE%"` in the wait loop | mitigate | The append writes ZERO bytes (`(call )` is a no-op) so the exe's contents cannot change, and the `if not exist "%EXE%" goto gone` guard means the redirection can never CREATE a file — which is the only way this construct could place something new on disk. |
| T-AXR-03 | Denial of Service | `sweep_temp_orphans_in` | mitigate | The matcher is anchored on both ends (prefix AND suffix) and built from the writer's own constants; directories are skipped; the current process's own script is skipped by name; an age guard blocks anything recent. A `remove_file` failure is logged and skipped, never retried in a loop. |
| T-AXR-04 | Information Disclosure | new log lines | mitigate | The sweep logs a COUNT and `e.kind()`, never a path. The helper's timeout log line goes to `update.log` on the owner's own disk, not to the wire; the D-11 vocabulary reaching the phone is untouched. |
| T-AXR-05 | Denial of Service | the timeout branch | mitigate | D-C: the timeout now relaunches, so a wait that times out for any reason can no longer leave the machine with no server — which is the shipped failure mode being repaired. |
| T-AXR-SC | Tampering | npm/pip/cargo installs | n/a | No new dependencies. `std::os::windows::fs::OpenOptionsExt` and `std::fs::OpenOptions` are std. Nothing is installed by this plan. |
</threat_model>

<verification>
From `server/`:

1. `cargo test -p server-windows` — green, including the two real-spawn tests
   running by default.
2. `cargo test --workspace` — green; `server-core` is untouched and must stay
   that way.
3. `cargo clippy -p server-windows --all-targets` — no new warnings.
4. Grep pins (run from the repo root, comment lines excluded where noted):
   - `grep -c 'DETACHED_PROCESS' server/server-windows/src/update/apply.rs` — the
     constant and its doc survive; the SPAWN must not use it. Confirm by
     reading the `spawn_helper` body, not by counting.
   - the generated script carries no `|`: proven by the test, not by grep.
5. Mutation verification from Task 2 recorded verbatim (RED with the flag
   restored, GREEN without it).
</verification>

<success_criteria>
- `spawn_helper` spawns with `CREATE_NO_WINDOW` alone; a test asserts
  `DETACHED_PROCESS` is not part of the flags.
- The generated helper script contains zero pipe characters and spawns zero
  child processes to decide whether to proceed.
- A wait timeout skips the installer, still relaunches the old server, and still
  deletes the downloaded setup exe.
- A real test executes `spawn_helper` and asserts on disk that the helper ran to
  completion: Setup invoked, marker honest, relaunch fired, script and setup exe
  both deleted. A second real test proves the wait actually waits while the exe
  is locked.
- Startup removes stale `rc-update-*.cmd` and `RemoteControl-Setup-v*.exe` from
  `%TEMP%` without ever removing this process's own, and without delaying the
  input path.
- `cargo test --workspace` passes. No version bump, no release, no installer or
  release-script changes.
</success_criteria>

<output>
Create `.planning/quick/260805-axr-fix-the-pc-self-update-helper-wedge-spaw/260805-axr-SUMMARY.md` when done.

It MUST record:
- the exact final text of the `:wait` block as generated (paste it from a test
  run with `--nocapture`, or from `helper_script`'s output);
- the mutation-verification result from Task 2, both runs, verbatim;
- the sweep's `MIN_ORPHAN_AGE` value and the count it reported on this machine's
  first real startup, if the developer ran the binary;
- an explicit restatement that delivery is NOT done: `1.6.2` must be built and
  installed BY HAND and `1.6.3` published as the tap target before 12-18 Task 4
  can be re-run, because the fix cannot ship through the path it repairs.
</output>
