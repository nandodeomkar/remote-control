---
created: 2026-08-05T02:15:00Z
title: PC self-update helper wedges before Setup runs — SC5 blocker, ships in 1.6.0/1.6.1
area: server
files:
  - server/server-windows/src/update/apply.rs:260
  - server/server-windows/src/update/apply.rs:104
---

## Problem

Found on real hardware during 12-18 Task 4 (the phase's on-hardware UAT). Tapping
**Update PC** on the phone exits the server and it **never comes back**. Setup never
runs. Phase 12's SC5 is not met, and SC7 was unreachable as a consequence.

Ships in **both `1.6.0` and `1.6.1`**, so every installed client has it.

### Directly observed

| Observation | Evidence |
|---|---|
| A console window appeared on the desktop | helper is spawned to have none; window titled `find "7556"` |
| The helper was **blocked, not spinning** | total CPU **0.03125 s** across 4+ minutes |
| It never completed one poll | so `MAX_WAIT_POLLS = 30` never armed — it would wait forever |
| Setup never ran | `%TEMP%\rc-setup.log` absent |
| Payload was fine | `%TEMP%\RemoteControl-Setup-v1.6.1.exe` present at 5,898,789 B — the published size |
| Old install untouched | `{app}\RemoteControl.exe` VERSIONINFO still `1.6.0` |
| Marker held the pessimistic write | `{"target":"1.6.1","ok":false,"error":"installer"}` |
| `update.log` absent | helper never reached any logging branch |
| Process identity | `cmd.exe /c ...\rc-update-7556.cmd`, PID 18152, parent PID 7556 (the dead server) |

### Ruled out — do not re-investigate

- **The batch logic.** Its exact wait test was run by hand against the dead PID:
  `tasklist /FI "PID eq 7556" /NH | find "7556"` fails, so the script would correctly
  `goto gone`.
- **Script generation.** The emitted `rc-update-7556.cmd` was read in full: every
  placeholder substituted, `__MAX_POLLS__` → `30`, CRLF as intended.
- **Download / verification.** Correct file, correct size; `begin_apply` is only reached
  after `verify_or_delete` succeeds.
- **The marker protocol.** It worked, and it is the only reason this was diagnosable at
  all — see below.

### Root cause

`spawn_helper` (`apply.rs:260`) spawns with
`.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW)` and all three stdio null.
**Those two flags are not a valid pair** — `CREATE_NO_WINDOW` is ignored when
`DETACHED_PROCESS` is set. The visible window proves the flag was not honored; the
resulting console/stdio state is what wedges `find` on its pipe read.

The flag half is proven by observation. The causal link to the `find` hang is one
inferential step and should be confirmed by a minimal repro (spawn the same script with
the current flags vs corrected flags) before committing a fix.

### Why no test caught it

`begin_apply_with` takes the spawn as an injected closure specifically so sequencing can
be tested "without starting a detached process that installs software". That is correct
test design — and it is exactly the seam the bug lives behind. `spawn_helper` is the one
function in this path that no test ever executes.

## Solution

1. **Fix the flags.** Drop the invalid pair. Verify with a repro that actually spawns a
   detached child — no unit test will ever cover the real `spawn_helper` through the
   existing closure seam.
2. **Reconsider `tasklist | find` for the PID wait.** The pipeline is what wedged. A
   pipe-free liveness check removes the failure mode instead of depending on the console
   state being right.
3. **Make the wedge survivable.** The 30-poll bound only guards a server that refuses to
   die, not a helper that never completes a poll. A wall-clock deadline would have
   relaunched the old server automatically instead of leaving the owner with no server.
4. **Clean up on the wedge path.** `del "%SETUP%"` and the script's self-delete both sit
   at `:end`, which a wedged run never reaches — so each attempt leaks
   `%TEMP%\rc-update-<pid>.cmd` plus a ~5.9 MB setup exe.

## Delivery constraint

**The fix cannot ship through the path it fixes.** The broken helper is inside `1.6.0`
and `1.6.1`, so re-running 12-18 Task 4 needs `1.6.2` installed **by hand** and `1.6.3`
as the tap target.

## What still worked, and should not be "fixed"

D-16's pessimistic-marker-before-spawn is the design choice that made this legible: no
logging ran, the helper never reached a reporting branch, and the process that knew an
update was happening had already exited — yet the outcome was still recoverable from
disk, naming both the target and the failing stage. On restart the server read and
deleted it and the phone rendered the fixed sentence *"The installer didn't finish"* with
no path, code, URL or hash. **D-24 is observed met**, by a real failure rather than
12-18 Task 4 step 6's planned hand-written stand-in.

## Reference

`.planning/phases/12-in-app-updates/12-18-SUMMARY.md` (`## Self-Check: FAILED`) and the
Wave 8 block in `.planning/STATE.md`.
