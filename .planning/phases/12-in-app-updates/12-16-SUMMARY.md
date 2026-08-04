---
phase: 12-in-app-updates
plan: 16
subsystem: updates
tags: [rust, javascript, inno-setup, extension, transport, security, guard-tests]
status: code-complete; Task 1 checkpoint OUTSTANDING

# Dependency graph
requires:
  - phase: 12-in-app-updates (12-13)
    provides: protoVersion 1.8 on the wire; the update family routed
  - phase: 12-in-app-updates (12-12)
    provides: the ext.hello extVersion capture and the ExtInfo relay watch
provides:
  - "ExtCmd::Reload and its dispatch arm — the ext.reload wire frame"
  - "should_nudge() — the pure D-18 version-drift decision, including the loop breaker"
  - "run_ext's server_version parameter and the once-per-target-version in-memory guard"
  - "extension/background.js's ext.reload arm calling chrome.runtime.reload()"
  - "extension_reloads_itself_on_command — the source-text guard that makes removing the arm a build failure"
  - "The hardened extension [Files] entry in installer/RemoteControl.iss"
affects: [12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A pure decision function beside an effectful handler, so the three ways to say 'no' are testable without a socket"
    - "Guard-set-in-the-same-step-as-emit, so there is no window between deciding to nudge and recording that the nudge happened"
    - "Quiet-window plus ordering-belt as the shape of a negative socket assertion: prove nothing arrives, then prove the NEXT thing that arrives is the expected one"
    - "Comment wording that avoids spelling a token a plan-check greps for a fixed count of, saying so at the point of omission (the 12-14 precedent)"

key-files:
  created: []
  modified:
    - server/server-core/src/transport/ext.rs
    - server/server-core/tests/ext_relay.rs
    - server/server-core/tests/extension_guard.rs
    - server/server-windows/src/main.rs
    - extension/background.js
    - installer/RemoteControl.iss

key-decisions:
  - "The nudge rides handle_ext_text's existing return channel rather than looping back through cmd_rx. A self-send into the mpsc that the same select! drains would be a needless round trip, and a full channel would silently drop the one nudge the design allows."
  - "The guard is keyed on the SERVER's version, not the extension's. The question it answers is 'have I already asked for this target', and the target is what the server wants the extension to become. Keying it on the extension's reported version would let two different stale versions each earn a nudge, which is not what once-per-target means."
  - "The guard is NEVER reset — not on session end, not in reset_relay_watches, not on a newest-wins replacement. A server restart is the only reset. Anything that cleared it would reopen the loop it exists to close, because the reload itself is what causes the reconnect that produces the second hello."
  - "The guard is set in the SAME step that emits the frame. A guard set anywhere else is a guard with a window in it."
  - "An absent extVersion never nudges. Unknown is not 'different' — a pre-1.8 extension omits the field, and reloading a browser worker on no evidence is not something this server does."
  - "run_ext takes server_version as a parameter rather than reading its own crate's package version (D-05). server-core is a library; its version is not what ships and is not what an extension should be compared against."
  - "reload_frame() spells the wire shape once, shared by the dispatch arm and the hello nudge, so neither can drift from background.js's case label."
  - "The harness default server version is 1.0.0, chosen to MATCH the extVersion the pre-1.8 scenarios already send, so those tests stay in the no-nudge case and their observations are unchanged by this plan."

patterns-established:
  - "Negative socket assertions get two halves: a bounded quiet window proving nothing arrived, and an ordering belt (send a ping, assert the next frame is the pong) proving nothing is queued behind it"
  - "A guard test whose failure message explains the SILENCE of the bug it catches, not just the rule — this one fails with no error on either side and no log line anywhere"

requirements-completed: [D-04, D-05, D-18]
requirements-pending: [SC7]

# Metrics
duration: 1 session
completed: 2026-08-04
---

# Phase 12 Plan 16: The Extension Reload Leg Summary

**The server notices the extension is running an older build than itself and nudges it exactly once per target version per process run; the extension answers by re-reading its files from disk; and a Chrome-held file can no longer take the whole PC install down with it.**

> **SC7 IS NOT CLAIMED.** Task 1 is a blocking human-action checkpoint and is **still outstanding** — see the section below. The code is complete and every automated gate is green, but whether the extension actually ends up on the new version after a real PC update is an observation nobody has made yet.

## ⚠ Task 1 — OUTSTANDING (blocking human-action checkpoint)

**Not performed. Not assumed. Not skipped quietly.**

The plan opens with a five-minute observation on a real machine, and says in terms: *"An agent cannot perform this and must not assume its outcome."* It requires loading an unpacked extension through `chrome://extensions` and running a real setup exe over a live install with the browser open — neither of which an agent can do.

### What still has to be observed

| Fact | Question |
|------|----------|
| **A** | The setup's exit code, and whether `%TEMP%\t.log` contains `ErrorReplacingExistingFile` or any Abort/Retry/Ignore entry |
| **B** | Whether the server exe itself was actually replaced |
| **C** | Whether the extension's `ext.hello` reports the NEW version after the reload, or still the old one |

### The procedure

1. Have the current release installed, so `{app}\extension` exists on disk.
2. Chrome (or Edge) → `chrome://extensions` → Developer mode → **Load unpacked** from the installed `{app}\extension`. Confirm it connects (the phone's browser screen shows tabs).
3. Leave the browser **open**.
4. Run the setup over the existing install:
   `RemoteControl-Setup-vX.Y.Z.exe /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG="%TEMP%\t.log"`
5. Record `%ERRORLEVEL%` immediately.
6. Search `%TEMP%\t.log` for `ErrorReplacingExistingFile`.
7. Watch the server log after relaunch: does the extension reconnect, and what `extVersion` does its `ext.hello` report?

### What each answer changes

- **A shows a replace failure AND B shows the server exe was NOT replaced** → the Pattern 5 mitigation is load-bearing; the comment in `RemoteControl.iss` changes from "may hold a write lock" to "does hold a write lock, observed".
- **A shows a failure but B shows the server was replaced anyway** → the mitigation is advisable, not load-bearing.
- **A is clean** → the flags stay as cheap insurance and the comment records that the lock was NOT reproduced on this machine.
- **C** decides whether SC7 is met outright or only in its degraded form ("Restart your browser to finish updating"). Either way the feature degrades rather than breaks — but the claim must follow the observation, not the code.

**Nothing in the shipped code is waiting on this.** Both branches of Task 3's installer decision produce the same two flags, which is why Tasks 2 and 3 were completed rather than parked. What is waiting is the SC7 claim and the confirmed/not-reproduced wording of one comment.

**When the facts are reported, this section is replaced with them verbatim** and the SC7 line below is settled.

## Performance

- **Duration:** ~1 session (Tasks 2 and 3; Task 1 outstanding)
- **Tasks:** 3 (2 complete, 1 blocked on a human action)
- **Files modified:** 6
- **Tests added:** 7 (6 socket, 1 source-text guard)

## Accomplishments

- **The drift is noticed exactly once.** `should_nudge` is a pure three-clause decision: no reported version → no nudge; a matching version → no nudge; an already-attempted target → no nudge. The third clause is the loop breaker, and it is the reason a Chrome-blocked overwrite degrades to a message instead of a permanent reload cycle.
- **The loop assertion is the load-bearing test.** Two consecutive `ext.hello` frames carrying the same stale version produce exactly ONE `ext.reload` — proven twice over: a bounded quiet window showing nothing arrives, then an ordering belt showing the next frame the relay sends is the pong, so nothing is queued behind the window either.
- **The guard outlives the session, because the nudge kills the session.** `chrome.runtime.reload()` terminates the worker, so the next hello arrives on a brand-new connection. A test drops the socket, waits for the watch to reset, reconnects and helloes again with the same stale version — and asserts silence. A per-session guard would be exactly as open as no guard at all.
- **The nudge carries nothing.** `ExtCmd::Reload` has no payload: no path, no url, no version. The extension reloads itself from wherever it was already loaded and this command cannot redirect that (T-12-01).
- **The extension arm is pinned by a guard that fails loudly for a bug that fails silently.** Without the arm, the server still sends the nudge, the guard still records it, and nothing anywhere raises an error — the only symptom is a version mismatch on the phone that never clears. The mutation check was performed: removing the arm turns `extension_reloads_itself_on_command` red; restoring it turns it green.
- **A locked extension file can no longer abort the whole install.** The `[Files]` entry now schedules a blocked replacement for next boot via `MoveFileEx` instead of raising an Abort/Retry/Ignore whose suppressed default is Abort — and `/SUPPRESSMSGBOXES` is precisely how the in-app updater invokes Setup. The server exe entry stays listed first so the critical artifact lands before the risky one.
- **The version compared against is the one that ships.** `run_ext` takes `server_version` from the composition root; `server-core`'s own package version is a library version and would have been the wrong answer (D-05).

## Task Commits

1. **Task 1: observe whether Chrome blocks the extension overwrite** — **OUTSTANDING** (no commit; human action)
2. **Task 2: ExtCmd::Reload and the once-per-target-version guard** — `1f147e1` (feat)
3. **Task 3: the extension arm, its guard test, and the installer hardening** — `23027e6` (feat)

## Files Created/Modified

- `server/server-core/src/transport/ext.rs` — `ExtCmd::Reload`, `reload_frame()`, `should_nudge()`, `run_ext`'s `server_version` parameter and `reload_attempted_for` local, the dispatch arm, and the nudge inside the `ext.hello` handler
- `server/server-core/tests/ext_relay.rs` — `spawn_relay_with_version`, `HARNESS_SERVER_VERSION`, `QUIET_WINDOW`, `expect_no_frame`, and 6 tests
- `server/server-core/tests/extension_guard.rs` — `extension_reloads_itself_on_command`
- `server/server-windows/src/main.rs` — the shipping version passed to `run_ext`
- `extension/background.js` — `case "ext.reload": chrome.runtime.reload(); break;`
- `installer/RemoteControl.iss` — two flags on the extension `[Files]` entry plus the rationale comment

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Task 1 could not be performed**

- **Found during:** Task 1
- **Issue:** It requires interacting with `chrome://extensions` and running a real installer over a live install. The plan states an agent cannot do this and must not assume the outcome.
- **Fix:** Not faked and not skipped. Tasks 2 and 3 were completed in full because nothing in either depends on the answer — both branches of the installer decision produce the same two flags. The SC7 claim is explicitly withheld, and the outstanding facts are recorded above with the procedure so the checkpoint can be closed without re-deriving it.
- **Verification:** the `⚠ Task 1` section above; the SC7 line in Success Criteria below.
- **Committed in:** `23027e6` (the commit message carries the same note)

**2. [Rule 2 - Missing Critical] The nudge needed a delivery path the plan did not specify**

- **Found during:** Task 2
- **Issue:** The plan says "send `ExtCmd::Reload` to the extension" from the `ext.hello` handler. But that handler runs *inside* `run_ext`'s `select!`, and the only `ExtCmd` path is the mpsc that the same `select!` drains — a self-send, which is a needless round trip and silently drops the nudge if the channel is full.
- **Fix:** The nudge is returned through `handle_ext_text`'s existing `Option<Message>` channel, the same one `ext.pong` already uses. `ExtCmd::Reload` and its dispatch arm still exist as the plan requires, and both paths serialise through one `reload_frame()` so they cannot diverge. A test covers the dispatch arm directly.
- **Files modified:** `server/server-core/src/transport/ext.rs`
- **Verification:** `ext_cmd_forwards_reload_frame` (the dispatch arm) and `ext_reload_guard_nudges_a_stale_extension` (the hello path) assert the same frame.
- **Committed in:** `1f147e1`

**3. [Rule 1 - Bug] Three of this plan's own comments tripped its own grep gates**

- **Found during:** Tasks 2 and 3
- **Issue:** The acceptance criteria require `CARGO_PKG_VERSION` to appear **0** times in `ext.rs`, `restartreplace` **1** time in the `.iss`, and `deleteafterinstall` **0** times. Explaining each rule naturally meant spelling the token — the `ext.rs` doc comment said "deliberately NOT `env!("CARGO_PKG_VERSION")`", and the `.iss` comment both named the flags and said "do not add `deleteafterinstall`". Counts came back 1, 2 and 1.
- **Fix:** All three reworded to state the rule without spelling the token, each noting at the point of omission that a plan-check greps for it — the 12-14 precedent, applied a second time.
- **Files modified:** `server/server-core/src/transport/ext.rs`, `installer/RemoteControl.iss`
- **Verification:** the counts are now 0, 1 and 0.
- **Committed in:** `1f147e1`, `23027e6`

**4. [Rule 2 - Missing Critical] The test harness needed a settable server version**

- **Found during:** Task 2
- **Issue:** `spawn_relay()` had no notion of a server version, and the pre-existing scenarios send helloes with `extVersion` `1.0.0` and `1.5.0`. An arbitrary default would have injected unread `ext.reload` frames into unrelated tests' sockets.
- **Fix:** `spawn_relay_with_version` for the drift tests, with `spawn_relay()` defaulting to `HARNESS_SERVER_VERSION = "1.0.0"` — chosen to MATCH what the older scenarios already send, so they stay in the no-nudge case and their observations are unchanged.
- **Files modified:** `server/server-core/tests/ext_relay.rs`
- **Verification:** all 19 pre-existing `ext_relay` tests still pass unmodified.
- **Committed in:** `1f147e1`

**5. [Rule 3 - Note] `server/server-core/src/executors/mod.rs` was listed but needed no change**

- **Found during:** Task 2
- **Issue:** The plan's `files_modified` includes it. `ExtInfo` already lives there from 12-12 and nothing this plan does touches it.
- **Fix:** Left untouched. Noted so the file list's inaccuracy is not read as a missed step.
- **Committed in:** n/a

---

**Total deviations:** 5 (1 blocking-and-outstanding, 2 missing-critical, 1 bug, 1 note). No architectural change, no new dependency, no scope creep.

## Decisions Made

See `key-decisions` in the frontmatter. The four a later plan should not re-litigate:

- **Never reset the guard.** Not on session end, not in `reset_relay_watches`, not on a newest-wins replacement. The reload *causes* the reconnect that produces the second hello, so anything that clears the guard reopens the loop.
- **Key the guard on the server's version.** "Have I already asked for this target" is the question; the target is the server's version.
- **An absent `extVersion` never nudges.** Unknown is not different.
- **`run_ext` is handed the version, it does not read one.** `server-core` is a library and its own package version is not what ships.

## Issues Encountered

- **A negative assertion over a socket needs two halves.** A bounded quiet window alone proves only that nothing arrived *yet*. The ordering belt — send a ping, assert the next frame is the pong — proves nothing is queued behind the window either. Both are in the loop test, because that test is the one the whole plan turns on.
- **The `.iss` comment is longer than the line it documents, deliberately.** It records that the mitigation contradicts the design spec's "no `.iss` change is needed" claim, why that claim was right about the `[Run]` entry and wrong here, and the two things the flags do *not* guarantee (a per-user install may not be able to write the pending-rename key; a next-boot replacement leaves the old files loaded for the rest of the session). A future reader deleting the flags without that context would reintroduce a total-install-failure mode that only shows up when a browser is open.

## Verification Results

| Gate | Result |
|------|--------|
| `cargo test -p server-core ext_reload_guard` | **5 passed**, 0 failed |
| `cargo test -p server-core --test ext_relay` | **25 passed** (was 19) |
| `cargo test -p server-core --test extension_guard` | **5 passed** (was 4) |
| `cargo test --workspace` | **312 passed** (was 305), 0 failed, 2 ignored |
| Mutation check: arm removed | `extension_reloads_itself_on_command` **FAILED** (4 passed, 1 failed) — recorded as required |
| Mutation check: arm restored | **5 passed** |
| `grep -c 'ExtCmd::Reload' ext.rs` | 2 (>= 2 — the variant and the dispatch arm) |
| `grep -c 'CARGO_PKG_VERSION' ext.rs` | 0 |
| `grep -c 'CARGO_PKG_VERSION' server-windows/src/main.rs` | 2 (>= 1) |
| `grep -c 'chrome.runtime.reload' background.js` | 1 |
| `grep -c 'restartreplace' RemoteControl.iss` | 1, on the extension `[Files]` line only |
| `grep -c 'deleteafterinstall' RemoteControl.iss` | 0 |
| `[Files]` ordering | server exe at line 98, extension at line 135 — exe first, unchanged |

### The six new socket tests

| Test | What it pins |
|------|--------------|
| `ext_reload_guard_nudges_a_stale_extension` | a differing version gets one `ext.reload` with an empty payload, and the watch still reports the OLD version |
| `ext_reload_guard_does_not_loop_on_a_repeated_stale_hello` | **the loop assertion** — a second identical stale hello sends nothing, proven by quiet window and by pong ordering |
| `ext_reload_guard_stays_silent_on_a_matching_version` | an up-to-date extension is never reloaded |
| `ext_reload_guard_stays_silent_without_an_ext_version` | absent, null and non-string `extVersion` all send nothing |
| `ext_reload_guard_survives_a_reconnect_in_the_same_process_run` | the guard outlives the session its own nudge ended |
| `ext_cmd_forwards_reload_frame` | the dispatch arm serialises the same frame the nudge does |

## Known Stubs

None in code.

**One outstanding observation**, recorded above: Task 1's facts A, B and C.

## Success Criteria

| Criterion | Status |
|-----------|--------|
| The reload guard fires once per target version per process run and is proven not to loop | **MET** — asserted by socket test |
| The extension arm exists and is pinned by a source-text guard test | **MET** — mutation check performed |
| The installer can no longer be aborted in full by a single locked extension file | **MET in code**; the lock itself is unobserved (Task 1 fact A) |
| SC7 — the extension runs the new version after a PC update without touching `chrome://extensions` | **NOT OBSERVED.** Every mechanism is in place and tested, but the end-to-end outcome depends on Task 1 fact C. Do not claim SC7 until it is reported. |

## Threat Flags

None beyond the plan's register.

- **T-12-56** (reload loop) — mitigated and asserted by the plan's most important test.
- **T-12-57** (a locked file aborting the whole install) — mitigated in the `[Files]` entry; the underlying lock is still unobserved, which is Task 1's fact A.
- **T-12-01** — `ext.reload` carries nothing; it cannot redirect where the extension loads from.
- **T-12-55** (a local process forging a stale `ext.hello`) — accepted as planned; the bounded consequence is at most ONE `chrome.runtime.reload()` per process run, which is exactly what the guard bounds.
- **T-12-58** (`_metadata`) — accepted; no clean-directory step was added, deliberately.

## User Setup Required

**Task 1's observation** — see the section at the top. It is the only thing standing between this plan and a settled SC7 claim.

## Next Phase Readiness

Wave 8 is `12-18` (the version bumps and the full UAT), which depends on `12-15`, `12-16` and `12-17` — all three now code-complete.

For `12-18`:

- It is `autonomous: false` and additionally needs a physical Android phone on the same LAN, with the install-unknown-apps grant **declined once** so the D-19 refusal path is observed.
- Task 1 of this plan can be folded into `12-18`'s UAT session — it is the same kind of activity (a real installer run on a real machine) and the phone is already in hand for the rest of it.
- The `ext.reload` path is only exercisable end to end with a real browser holding a real unpacked extension, which is the same session again.

## Self-Check: PARTIAL

All six files exist on disk with the described contents, and both code commits (`1f147e1`, `23027e6`) are present in `git log`. **Task 1 is not done**, and this summary says so in four places rather than burying it.
