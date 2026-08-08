---
phase: 12-in-app-updates
plan: 18
subsystem: distribution
tags: [release, uat, on-hardware, github-releases, packageinstaller, inno-setup, detached-process, d-16, sc4, sc5]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 03
    provides: "the public mirror and tools/release.ps1 exercised for real once, plus v1.5.0 as the version floor"
  - phase: 12-in-app-updates
    plan: 15
    provides: "the Updates screen and both badge placements this plan reads on a real phone"
  - phase: 12-in-app-updates
    plan: 16
    provides: "the ext.reload arm and the .iss restartreplace hardening this plan was to confirm post-hardening"
  - phase: 12-in-app-updates
    plan: 17
    provides: "the PC settings UPDATES section this plan reads as the second surface"
provides:
  - "Mirror release v1.6.0 — the first feature-complete release, three digest-bearing assets"
  - "Mirror release v1.6.1 — the update target, functionally identical to 1.6.0 by design"
  - "Private-repo tags v1.6.0 and v1.6.1, and the three version files at 1.6.1"
  - "SC4 observed met on a physical phone: APK self-update including the missing-grant and declined-dialog paths"
  - "A REPRODUCED, ROOT-CAUSED DEFECT in the PC apply path (D-16) that blocks SC5 — see Issues Encountered"
  - "D-24 observed met by a REAL failed apply: pessimistic marker → server exit → restart → phone shows the fixed 'installer' sentence, no path or code in it"
affects: [12-19-or-successor]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "The pessimistic marker is what made a wedged helper diagnosable at all — it survived the process that wrote it and named the failing stage without any logging having run."

key-files:
  created:
    - .planning/phases/12-in-app-updates/12-18-SUMMARY.md
  modified:
    - server/server-windows/Cargo.toml
    - server/Cargo.lock
    - app/remote_control/pubspec.yaml
    - extension/manifest.json

key-decisions:
  - "Release notes for both tags were rewritten after publish with `gh release edit`. tools/release.ps1 hardcodes a one-line note, and the plan requires v1.6.1's notes to state why two releases exist minutes apart. The script was not modified — it does not own release prose."
  - "Task 4 step 6's hand-written ok:false marker was NOT needed: the real failure produced a genuine pessimistic marker, which is strictly better evidence than a fabricated one. The stand-in was skipped as superseded, not skipped as unrun."
  - "On finding the D-16 defect the plan was STOPPED rather than extended into a fix. Fixing it requires a 1.6.2 installed by hand plus a 1.6.3 to test against — several release cycles, and a verification plan is the wrong container for that work. Owner chose this explicitly."
  - "requirements-completed lists only what was actually observed. Copying the plan's full requirements array verbatim, as the summary template instructs, would have marked D-16/D-17/D-18/SC5/SC7 complete when they are not."
  - "AMENDED 2026-08-08 by quick 260808-waa: D-16/D-17/D-18/SC5/SC7 moved from requirements-not-met to requirements-completed after the PC self-update was observed working on hardware (1.6.2 -> 1.6.3). The amendment touches the frontmatter arrays, the criteria table and an addendum ONLY — the 2026-08-05 observations of the wedge are left verbatim, because they are the evidence the defect was real."

requirements-completed: [D-04, D-07, D-16, D-17, D-18, D-19, D-20, D-21, D-24, SC1, SC2, SC3, SC4, SC5, SC7]
requirements-partial: [D-06, D-08, D-12, D-25, D-26]
requirements-not-met: []

# Metrics
duration: 7h 15m (mostly blocking human checkpoints; ~35 min of machine work)
completed: 2026-08-05
---

# Phase 12 Plan 18: Live Release and On-Hardware UAT Summary

**Two real releases published from the finished tree and the APK self-update proven end to end on a physical phone (SC4) — and the PC self-update proven BROKEN: the detached helper wedges before Setup ever runs, so SC5 is not met and the extension leg was never reached.**

## Performance

- **Duration:** 7h 15m wall clock (three blocking human checkpoints); roughly 35 min of machine work
- **Started:** 2026-08-04T18:54:58Z
- **Completed:** 2026-08-05T02:10:28Z
- **Tasks:** 3 of 4 complete; Task 4 failed at step 1
- **Files modified:** 4 (all by `tools/release.ps1`, across two release commits)

## Provenance

| Fact | Value |
|---|---|
| Tree HEAD before Task 1 | `1a45424` |
| v1.6.0 built from / bump commit | `74b5d95 chore(release): v1.6.0` (parent `1a45424`) |
| v1.6.1 built from / bump commit | `66ffd43 chore(release): v1.6.1` (parent `74b5d95`) |
| Suites at `1a45424` | `cargo test --workspace` 312 passed / 0 failed / 2 ignored (8 suites) · `flutter test` 832 passed · `dart test` (remote_protocol) 22 passed — **all three green** |

Published sha256, each equal to what the build machine printed and to the mirror's
anonymous per-asset `digest`:

```
RemoteControl-v1.6.0.apk            644772807650608dab7e616ca73877f2b87294b4363016d585e8b69757e89c19
RemoteControl-Setup-v1.6.0.exe      4776c96633907a924a9a6c15a5e221ad76de77e1db6f2c493b4790fe234bfb3e
RemoteControl-Extension-v1.6.0.zip  03078fb32e0d2ca06643344b5316f867312fbd772a6ad891d7318bbcfbc33d78

RemoteControl-v1.6.1.apk            1e72d09dd6de53f84c626b1005aef3d0863c55e13d493218b170ad88da463193
RemoteControl-Setup-v1.6.1.exe      bf00dd349665fa50162ad95800f3c72989aa87e14a4cb08e01b911d47abf3599
RemoteControl-Extension-v1.6.1.zip  d69bb1576841776af3ce9a0457d8202e348d9d664ca396cb461e448e94591215
```

## Task Commits

1. **Task 1: publish 1.6.0 then 1.6.1** — `74b5d95`, `66ffd43` (both `chore(release):`, written by the script)
2. **Tasks 2-4** — human checkpoints; no repository commits by design

**Plan metadata:** this summary.

## What Was Done

### Task 1 — two real publishes — COMPLETE

Dry run first (`-Version 1.6.0 -DryRun`): exit 0, **zero refusals**, three BUMP lines at
one version. Then both live runs, each exit 0.

Every acceptance criterion passes:

| Criterion | Result |
|---|---|
| anonymous `releases/latest` → `v1.6.1`, 3 assets, every `digest` matches `^sha256:[0-9a-f]{64}$` | PASS |
| anonymous `releases/tags/v1.6.0` → 200, exactly the 3 locked asset names, all digest-bearing | PASS |
| `grep '^version' server/server-windows/Cargo.toml` | `1.6.1` |
| `grep '^version:' app/remote_control/pubspec.yaml` | `1.6.1+11` — build number 9 → 11, **two higher**, as required |
| `grep '"version"' extension/manifest.json` | `1.6.1` |
| `git status --porcelain` | empty |
| plan's `<automated>` python probe | `OK latest=v1.6.1 baseline=v1.6.0` |

Both releases are `draft=False`, `prerelease=False`, every asset `state: uploaded`.
`v1.5.0` was left untouched, as instructed.

### Task 2 — both clients onto 1.6.0 — COMPLETE (with one recording gap)

Owner installed the `v1.6.0` assets from the `v1.6.0` tag (not `latest`) and reported
**"all working as described"** against the five observations:

1. PC settings `UPDATES` section — version line and check result as specified
2. Badge dot lit on **both** the Settings `Updates` row and the hub settings gear (D-06/D-07)
3. Three rows — App, PC, Extension — all installed `1.6.0`, all naming `1.6.1` as latest
4. App row showed a download size before any download (D-08)
5. Nothing downloaded unprompted — confirmed explicitly

**Recording gap, stated plainly:** the plan requires the download-size string *verbatim*.
It was not captured. The executor had printed a predicted value (`67 MB`, from the APK's
real 70,058,939 bytes) into the checkpoint prompt before asking, so a confirmation back
would have recorded the executor's arithmetic rather than the device's rendering. It was
requested separately and not supplied. **Recorded as observed-but-not-transcribed**, not
as met.

### Task 3 — APK self-update — COMPLETE, SC4 OBSERVED MET

Owner signalled `app updated`. Step outcomes, captured by explicit multiple choice rather
than inferred:

| Step | Outcome |
|---|---|
| 1-2 — grant revoked first | Explainer sheet appeared; dismissing left the row on "update available"; the sheet's button landed on the system install-unknown-apps screen scoped to this package |
| 3 — Cancel on Android's install dialog | Row returned to "update available" **once**, no automatic retry, no error sentence carrying a code or a path |
| 4 — the real install | App relaunched reporting `1.6.1` |
| 5 — D-26 after | App row reads up to date |
| cache — was the APK left behind? | **NOT OBSERVED.** Owner did not check. D-23's delete-on-every-path remains proven only by unit test |

**SC4 is observed met.** The grant path, the decline path and the successful install were
all exercised on a physical device against the real `v1.6.1` release.

### Task 4 — PC self-update — **FAILED AT STEP 1**

Owner tapped Update PC. The row moved downloading → verifying → restarting, **and the
server never came back.** A console window appeared on the desktop instead — which is
itself a defect, since the helper is spawned to have no window at all.

Steps 2, 3, 4, 5 and 7 were unreachable. See Issues Encountered.

**Step 6 was satisfied by the real failure rather than the hand-written stand-in.** After
the server was restarted on the still-installed `1.6.0`, the owner reported the phone's
Windows PC row reading:

> "The installer didn't finish"

That is the D-11 `installer` sentence surfacing from `lastUpdate` (D-24), on real hardware,
from a marker written by a genuinely failed apply — carrying **no path, no error code, no
URL, no HTTP status and no hash**, as D-11 requires. The full copy contract is
`The installer didn't finish. Your PC is still on {installed}.`; the owner reported the
leading clause. Whether it re-reports on a second open of the screen was not checked, so
the "exactly once" half of D-12 remains unconfirmed from the phone's side (it IS confirmed
from the server's: the marker file was gone immediately after the startup read).

## Issues Encountered

### THE BLOCKING DEFECT — the detached update helper wedges before Setup runs (D-16)

**Severity: blocks SC5. Present in shipped `1.6.0` and `1.6.1`.**

**Directly observed, not inferred:**

| Observation | Evidence |
|---|---|
| A console window appeared on the desktop | Screenshot from the owner, titled `find "7556"` |
| The helper was **blocked, not spinning** | `Get-Process 18152` → total CPU **0.03125 s** across 4+ minutes |
| It never completed a single poll | so the `MAX_WAIT_POLLS = 30` bound never armed; it would have sat there forever |
| Setup never ran | `%TEMP%\rc-setup.log` **absent** |
| The payload was fine | `%TEMP%\RemoteControl-Setup-v1.6.1.exe` present, 5,898,789 bytes — exactly the published asset size |
| The old install was untouched | `{app}\RemoteControl.exe` VERSIONINFO still `1.6.0` |
| The marker held the pessimistic write | `{"target":"1.6.1","ok":false,"error":"installer"}` |
| `update.log` absent | the helper never reached *any* logging branch |
| Process identity | `cmd.exe /c ...\rc-update-7556.cmd`, PID 18152, **parent PID 7556** — the dead server |

**What is NOT implicated** (each checked, not assumed):

- **The batch logic.** Its exact wait test was run by hand against the dead PID:
  `tasklist /FI "PID eq 7556" /NH | find "7556"` → fails → the script would correctly
  `goto gone`.
- **Script generation.** The emitted `rc-update-7556.cmd` was read in full: every
  placeholder substituted, `__MAX_POLLS__` → `30`, CRLF as intended.
- **The download or its verification.** Correct file, correct size, and `begin_apply` is
  only reached after `verify_or_delete` succeeds.
- **The marker protocol.** It worked exactly as designed and is the *only* reason this was
  diagnosable — see below.

**Root cause (high confidence, one inferential step):**
`spawn_helper` at `server/server-windows/src/update/apply.rs:260` spawns with
`.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW)` and all three stdio null.
**These two flags are not a valid pair** — `CREATE_NO_WINDOW` is ignored when
`DETACHED_PROCESS` is set. The visible window proves the flag was not honored; the
resulting console/stdio state is what wedges `find` on its pipe read. The causal link
between the two symptoms is the one step not yet proven by direct experiment, and a
minimal repro was offered and deferred.

**Why it was never caught earlier:** `begin_apply_with` takes the spawn as an injected
closure precisely so sequencing can be tested "without starting a detached process". That
is correct test design and it is also exactly the seam the bug lives behind — the real
`spawn_helper` is the one function in this path that no test ever executes.

**Recovery performed** (server was down; the plan authorises restarting it):
marker backed up to the session scratchpad first so the D-24 report would not be consumed
unobserved; stuck helper PID 18152 killed; `{app}\RemoteControl.exe` started. Server came
back on port 17777 at `02:08:15Z`, still `1.6.0`. The marker was consumed on the startup
read — `take_marker` deletes on read, as documented — confirming that half of D-12 on real
hardware.

Server log, the whole sequence:

```
02:01:40 update::apply: update: helper spawned; exiting to let the installer replace this exe
02:01:41 update_thread: update: exiting so the installer can replace this exe
02:08:15 server-windows listening port=17777          <- manual restart, 6 min later
```

### Not a defect: the pessimistic marker earned its keep

D-16's "write the marker BEFORE spawning the helper" is the single design choice that made
this failure legible. No logging ran, the helper never reached a branch that could report
anything, and the process that knew an update was happening had already exited — and the
outcome was still recoverable from disk, naming both the target and the failing stage.

## Deviations from Plan

**1. [Rule 3 — Blocking] Task 4 could not proceed past step 1**

- **Found during:** Task 4, step 1.
- **Issue:** the defect above. The server exited and was never replaced or relaunched.
- **Handling:** diagnosed to root cause, PC restored to a working `1.6.0`, and the plan
  **stopped** rather than extended into a fix — owner's explicit choice. Steps 2-5 and 7
  are unreachable without a fixed helper.
- **Not worked around.** The plan says a server that never comes back is the D-25 path and
  must be reported, not treated as a silent failure.

**2. [Superseded] Task 4 step 6's hand-written marker was not written**

The step exists to stand in for a non-zero installer exit "because it is not reproducible
on demand". It became reproducible: a genuine pessimistic marker was produced by a real
failure and consumed by a real startup read. Writing a fabricated one afterwards would have
been weaker evidence, not additional evidence.

**3. [Process] Release notes edited after publish**

`tools/release.ps1` writes a fixed one-line note. The plan requires v1.6.1's notes to state
why two releases exist minutes apart. Both releases' notes were set with `gh release edit`
after publishing. The script was not changed — it does not own release prose, and this plan
does not own the script.

**4. [Recording] Two observations were confirmed but not transcribed verbatim**

The App row's download-size string (Task 2) and the app-cache state after install
(Task 3). Both are recorded above as gaps rather than filled by inference, which the plan's
acceptance criteria explicitly forbid.

---

**Total deviations:** 1 blocking (unresolved by design), 1 superseded, 1 process, 1 recording.
**Impact on plan:** Task 1 and Task 3 fully achieved their purpose. Task 4's purpose —
demonstrating SC5 and SC7 — was not achieved, and the reason is a real product defect
rather than a test-environment problem.

## Success Criteria Status

| Criterion | Verdict |
|---|---|
| **SC1** — two releases no hand could have produced inconsistently | **MET** |
| **SC2** — every surface reports the version of the package it runs, at three versions | **PARTIAL as of 2026-08-05** — phone did `1.6.0` → `1.6.1`; the PC never left `1.6.0`. **MET 2026-08-08** — the PC went `1.6.2` → `1.6.3` and the extension with it; see the Addendum |
| **SC3** — row-state matrix exercised against a live feed | **MET** |
| **SC4** — APK updated itself on a physical phone, grant and decline paths included | **OBSERVED MET** |
| **SC5** — the PC replaces itself and comes back | **NOT MET as of 2026-08-05** — the helper wedges; Setup never runs. **OBSERVED MET 2026-08-08** after the `260805-axr` fix shipped in `1.6.2`; see the Addendum |
| **SC7** — extension reaches the new version, or degrades as D-18 documents | **NOT TESTED as of 2026-08-05** — unreachable, since the PC update never completed. (12-16 Task 1 observed SC7 met against fabricated 1.5.1/1.5.2 builds; that observation stands and is *not* superseded by this one.) **OBSERVED MET 2026-08-08** on a real release pair — see the Addendum |
| **D-21** — a release postdating the implementation exists | **CLOSED** |

**D-24 is observed met on real hardware, and by a genuine failure rather than a simulated
one.** The full chain ran end to end: the server wrote the pessimistic marker before
spawning, the apply failed, the restarted server read and deleted the marker, and the phone
rendered the fixed `installer` sentence — "The installer didn't finish" — on the Windows PC
row, with no path, code, URL, status or hash in it. This is the single strongest result in
the plan, and it was produced by the defect rather than despite it.

**D-12** is confirmed on the server side (marker written pessimistically, deleted on the
startup read) and on the reporting side (the phone did surface it). The **"exactly once"**
clause is the one part unconfirmed — nobody reopened the screen to check the failure does
not appear a second time.

**D-25** was exercised for real rather than simulated: the server genuinely never came
back. The row copy the phone displayed *during* the gap was not captured verbatim; what was
captured is what it read *after* recovery.

## User Setup Required

None outstanding. The plan's three `user_setup` services were all satisfied inline during
execution and verified at the point of use — `gh auth status` exit 0 as `nandodeomkar`
before Task 1, the physical phone on the LAN with the grant revoked on demand for Task 3,
and the PC with the browser held open from Task 2. No `12-USER-SETUP.md` was generated,
because it would document setup that had already been completed and verified rather than
setup still required.

## Next Phase Readiness

**Phase 12 is NOT complete.** It is 18/18 plans executed but one success criterion is
demonstrably false.

> **SUPERSEDED 2026-08-08.** All four items below were done — 1–3 by quick
> `260805-axr`, item 4 by quick `260808-waa`. Phase 12 now meets its goal. The list is
> kept because it is the record of what was owed; see the Addendum for what discharged it.

What a follow-up plan must do, in order:

1. **Fix `spawn_helper`.** Drop the invalid flag pair. Whatever replaces it must be
   verified by a repro that actually spawns a detached child — the existing injected-closure
   seam guarantees no unit test will ever cover the real one.
2. **Reconsider `tasklist | find` for the PID wait.** The pipeline is what wedged. A
   pipe-free liveness check would remove the failure mode instead of relying on the console
   state being right.
3. **Make the wedge survivable.** The 30-poll bound only protects against a server that
   refuses to die; it does not protect against a helper that never completes a poll. A
   wall-clock deadline would have relaunched the old server automatically instead of leaving
   the owner with no server at all.
4. **Then, and only then, re-run this plan's Task 4** — which needs `1.6.2` installed by
   hand (the broken helper ships inside `1.6.0`, so the fix cannot be delivered by the path
   it fixes) and `1.6.3` as the tap target.

Carried forward for whoever picks this up:

- **`v1.6.1` is the version floor now.** Any later release must be strictly greater or
  `release.ps1` refuses it as an argument error, which throws even under `-DryRun`.
- **`release.ps1` is still not idempotent after a publish-stage failure**, and still has no
  empty-mirror preflight. Both were carried from 12-03 and neither bit this run.
- **The stuck helper leaves `%TEMP%\rc-update-<pid>.cmd` behind**, since it self-deletes
  only on the way out. A wedged run leaks one file per attempt.
- **A killed helper also leaves the downloaded setup exe in `%TEMP%`** — `del "%SETUP%"`
  is at `:end`, which a wedge never reaches.

## Addendum 2026-08-08 — Task 4 re-run, SC5 and SC7 OBSERVED MET

Recorded by quick `260808-waa`. **Everything above this heading is the 2026-08-05 record
and has not been edited** — the wedge was real, and its evidence is why the fix exists.

### What shipped between the two runs

| Step | Result |
|---|---|
| `spawn_helper` fixed | quick `260805-axr` — commits `fad11fe`, `e585784`, `65ddf91` |
| `v1.6.2` published as a **pre-release** | commit `6dc6e27`, tag `v1.6.2`. Pre-release on purpose: `/releases/latest` excludes them, so the installed `1.6.1` was never offered an update its own broken helper would wedge on |
| `v1.6.2` installed **by hand** | `/VERYSILENT /NORESTART /SUPPRESSMSGBOXES`, exit 0. Local file digest `35edc37c…a0ef22`… equalled the published asset digest byte-for-byte, so the hand-install and the feed agree on what `1.6.2` is |
| `v1.6.3` published as a **normal** release | commit `f0d1aaa`, tag `v1.6.3`, three digest-bearing assets, anonymous `latest` = `v1.6.3` |

This is the delivery shape the 2026-08-05 record predicted was necessary: the fix could
not ship through the path it repairs.

### The run, verbatim

`%APPDATA%\RemoteControl\logs\server.log.2026-08-08` (UTC) interleaved with
`%TEMP%\rc-setup.log` (local, UTC+05:30 — the same instants):

```
17:41:36.065972Z  update: helper spawned; exiting to let the installer replace this exe
23:11:37.582      Log opened.  Original Setup EXE: %TEMP%\RemoteControl-Setup-v1.6.3.exe
23:11:37.582      Setup command line: /SL5="..." /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG="...\rc-setup.log"
23:11:38.086      Successfully installed the file.
23:11:38.090      Successfully installed the file.
23:11:38.093      Successfully installed the file.
23:11:38.096      Successfully installed the file.
23:11:38.594      Need to restart Windows? No
17:41:39.041889Z  server-windows listening port=17777
```

**Three seconds, helper spawn to server back up.** The same call wedged indefinitely on
`1.6.0`/`1.6.1`.

Owner-observed in the same run, the two legs no log can show:

- **The browser extension reloaded itself**, no manual action. SC7.
- **The phone reconnected on its own.** No `pcDidNotReturn`, no error state.

### Machine state confirmed afterwards

| Check | Result |
|---|---|
| `{app}\RemoteControl.exe` VERSIONINFO | `1.6.3` |
| Uninstall registry `DisplayVersion` | `1.6.3` |
| `{app}\extension\manifest.json` | `1.6.3` |
| Server process | PID 14644, up since 23:11:38 |
| Console window | none — `CREATE_NO_WINDOW` alone is honored |
| `ErrorReplacingExistingFile` / Abort / Retry / Ignore | none |
| Marker file in `%APPDATA%\RemoteControl` | absent — written, consumed, deleted |
| `%TEMP%\rc-update-*.cmd` and setup exe | both gone — the `:end` `del` ran |
| UAC | none (`User privileges: None`, per-user install) |

All four `260805-axr` remedies are now proven on hardware, including one that proved
itself before the update even ran: the `1.6.2` server's startup sweep logged
`update: removed 2 stale update file(s) from the temp directory`, clearing exactly the
`rc-update-7556.cmd` and `RemoteControl-Setup-v1.6.1.exe` that the 2026-08-05 wedge had
leaked — PID 7556 is the dead server named in the original defect record.

### What this does NOT close

- **The root cause stays inferential.** The flag half was observed; the causal link from
  the flag pair to the blocked `find` never reproduced in-harness. Both halves were
  fixed, so the repair does not depend on which one was load-bearing — but nobody
  isolated it, and nobody should later claim otherwise.
- **RESEARCH OQ-1, the Chrome file-lock question, is still open.** The `1.6.3` install
  scheduled no `restartreplace` and hit no `ErrorReplacingExistingFile`, so the deferred-
  replacement path in `RemoteControl.iss` remains unexercised — same outcome as 12-16
  Task 1. Not a defect; still unproven.
- **D-12's "exactly once" clause** is still unconfirmed, unchanged from the original run.

## Self-Check: FAILED (2026-08-05) — Task 4 line superseded 2026-08-08

- `.planning/phases/12-in-app-updates/12-18-SUMMARY.md` — FOUND
- commit `74b5d95` — FOUND
- commit `66ffd43` — FOUND
- tags `v1.6.0`, `v1.6.1` — FOUND
- mirror `v1.6.0` and `v1.6.1`, three digest-bearing assets each — FOUND (anonymous)
- three version files at `1.6.1` / `1.6.1+11` / `1.6.1` — FOUND
- `git status --porcelain` empty — CONFIRMED
- **Task 4 acceptance criteria — FAILED.** The PC row never reached `1.6.1`, the two
  surfaces could not be compared, the extension leg never ran, and the post-hardening
  file-lock question (RESEARCH OQ-1) is still open at the `1.6.x` installer.
  **SUPERSEDED 2026-08-08 (quick `260808-waa`):** re-run on `1.6.2` → `1.6.3` passed —
  the PC row reached `1.6.3`, both surfaces agree, and the extension leg ran and
  self-reloaded. RESEARCH OQ-1 alone remains open. See the Addendum above.

---
*Phase: 12-in-app-updates*
*Completed: 2026-08-05*
