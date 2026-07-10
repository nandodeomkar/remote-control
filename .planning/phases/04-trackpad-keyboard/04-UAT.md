---
status: complete-with-issues
phase: 04-trackpad-keyboard
source: [04-01-SUMMARY.md, 04-02-SUMMARY.md, 04-03-SUMMARY.md, 04-04-SUMMARY.md, 04-05-SUMMARY.md, 04-06-SUMMARY.md, 04-07-SUMMARY.md, 04-08-SUMMARY.md, 04-09-SUMMARY.md]
mode: mvp
user_story: "As a laptop owner, I want to use my phone as a precise mouse and full keyboard for my Windows laptop, so that it replaces a real trackpad and keyboard — not a toy."
started: 2026-07-10T09:30:00Z
updated: 2026-07-10T09:30:00Z
---

## Current Test
<!-- OVERWRITE each test - shows where we are -->

number: 5
name: Modifiers, autorepeat, rollover, disconnect mid-lock
status: issue logged — UAT complete, gap routed to fix planning

## Tests

### 1. Cold Start Smoke Test
expected: Kill any running server. Start the Windows tray server fresh, launch the app on the phone, connect. Server boots clean, phone connects, trackpad moves the PC cursor.
result: pass

### 2. Pointer precision & multi-monitor tracking
expected: With Windows "Enhance pointer precision" ON, a slow small phone drag moves the cursor 1:1 (no ballistics suppression). On a dual-monitor PC, the cursor crosses the seam onto the secondary display and back with no jump or clamp.
result: pass

### 3. Full gesture set vs Remote Mouse (feel benchmark)
expected: Move/tap/two-finger-tap/L-M-R buttons/scroll-momentum/drag-lock all work and feel at least as good as Remote Mouse. Drag-lock pill appears on long-press and a tap drops it. Sensitivity slider changes feel live and persist. WR-04 path — lift one of two scrolling fingers and keep scrolling: the remaining finger scrolls at FULL rate (not half).
result: pass
note: Initial failure ("can only drag cursor, cannot tap") was a STALE APK on the phone — old build predated the phase-04 classifier tap path. Diagnosed via L/M/R-bar discriminator (bar clicked, finger-taps didn't). Fresh release APK installed + re-pair → full gesture set works. NON-BLOCKING UI COMPLAINT logged in Gaps: overall trackpad/app UI judged "horrible" by owner.

### 4. IME typing fidelity + reconnect no-replay
expected: Open the keyboard panel, type with autocomplete, insert a multi-codepoint emoji, rapid-backspace across it — PC text matches the phone exactly (autocomplete revisions, emoji as one grapheme, correct backspace counts). Trackpad still moves the cursor while the panel + system IME are up. Then kill WiFi mid-typing, reconnect, type one character — PC receives ONLY that character, no replay of pre-disconnect text (CR-01 fix).
result: pass
note: CR-01 no-replay confirmed on device. Owner observation logged in Gaps: a character typed WHILE disconnected is delivered to the PC after reconnect (sendReliable auth-gated FIFO ≤10 flushes on re-auth).

### 5. Modifiers, autorepeat, rollover, disconnect mid-lock
expected: Arm Win, tap D — desktop shows, Win chip auto-resets. Lock Ctrl (long-press), hold Right in a text editor — repeats word-by-word while held, stops instantly on release. Roll from held Right onto Down (press Down before releasing Right) — BOTH arrows release, no key keeps autorepeating (CR-02 fix). Kill the connection mid-lock — chips reset, no key stays held on the PC.
result: issue
reported: "Everything worked except when I disconnected while holding shift key, the key remained held on the PC" — Win+D, Ctrl+Right autorepeat/stop, and CR-02 rollover all pass; abrupt-disconnect release fails.
root_cause: CONN-07 release_all (session.rs:158) only runs after the read loop exits, but an abrupt WiFi kill leaves a half-open TCP connection — stream.next() never yields None/Err (no FIN/RST). run_session has NO liveness mechanism: no ping deadline, no idle timeout, no TCP keepalive. Server holds Shift until the OS TCP stack times out. Graceful closes clean up correctly (why all automated tests pass).

## Summary

total: 5
passed: 4
issues: 1
pending: 0
skipped: 0

## Gaps

- severity: cosmetic (non-blocking)
  area: UI polish — trackpad screen / app-wide
  reported: 2026-07-10, during Test 3
  description: Owner verdict — functionality works but "the ui is horrible." Phase-04 UI does not yet meet the locked dark-minimal mockup bar (#0E0F12, blue accent, modern minimal). Needs a dedicated UI polish pass (candidate: /gsd-ui-review 6-pillar audit → polish phase or plan).
  routing: does not block phase-04 goal (usability/fidelity verified); route to UI review/polish backlog.

- severity: minor (design decision needed, non-blocking)
  area: offline input queueing — send_policy auth-gated FIFO
  reported: 2026-07-10, during Test 4
  description: Typing while WiFi is disconnected queues TextMsg frames in the sendReliable bounded FIFO (≤10) and flushes them into the PC after reconnect/re-auth. CR-01 (replay of PRE-disconnect text) is fixed; this is text typed DURING the disconnect being delivered late — technically the queue working as designed (T-04-05 mitigation notes the bounded FIFO), but it lands in whatever window is focused at reconnect time, same phantom-input flavor as D-12. Decision needed: keep (lossless brief-drop UX for clicks) vs drop keyboard/text frames queued while disconnected (predictability). Candidate: clear or filter the reliable queue on the disconnected transition.
  routing: backlog / discuss at next phase planning (touches send_policy.dart contract + T-04-05 wording).

- severity: major (blocks SC4 "reset safely on disconnect" under abrupt network loss; phantom held input — T-04-04/CONN-07 threat class)
  area: server session liveness — server-core/src/transport/session.rs
  reported: 2026-07-10, during Test 5
  description: Disconnect (WiFi kill) while a locked modifier is physically held leaves the key held on the PC. CONN-07 release_all is straight-line code AFTER the read loop (session.rs:158) and the loop only breaks when stream.next() yields None/Err — a half-open TCP connection (abrupt WiFi loss: no FIN, no RST) never yields either. run_session's select! has no liveness branch: no application ping deadline, no idle timeout, no TCP keepalive. Held input survives until the OS TCP timeout (minutes or longer). All graceful teardown paths (clean close, socket error, oversize frame, version reject) clean up correctly, which is why the automated suite passes.
  missing:
    - "Liveness deadline in run_session's select!: track last-inbound-frame Instant; a tokio interval branch breaks 'read when now - last_frame > threshold (e.g. 10-15s, >= 2x the client's protocol ping cadence) — CONN-07 cleanup then fires on the existing straight-line path"
    - "Regression test: session with held key receives no frames past the deadline → release_all fires (mock time or short test threshold)"
  routing: /gsd-plan-phase 4 --gaps (new gap-closure plan, server-core)
