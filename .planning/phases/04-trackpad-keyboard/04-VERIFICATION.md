---
phase: 04-trackpad-keyboard
verified: 2026-07-10T10:03:29Z
status: passed
score: 5/5 roadmap success criteria verified
human_verification_completed: 2026-07-10 — both gates passed on device (Xiaomi 25080RABDI): WiFi-kill re-test (Shift released within ~10s, chips reset on reconnect) and slow-PIN pairing (20-30s pause survived, pairing completed first connection)
overrides_applied: 0
re_verification:
  previous_status: human_needed
  previous_score: 5/5
  gaps_closed:
    - "04-UAT Test 5 MAJOR gap (half-open WiFi kill leaves locked modifier held on the PC, SC4/SC5/KEY-04/T-04-04): closed by 04-10 — LIVENESS_TIMEOUT (10s post-auth) sleep_until branch in run_session's select! breaks 'read onto the existing straight-line CONN-07 release_all; commits baff15a (RED), d269c05 (fix), 71e5f59 (docs); regression test half_open_silence_releases_held_input green"
    - "Review CR-01 (unconditional 10s deadline killed pre-auth sessions mid-PIN-entry — deterministic pairing regression): closed same session — deadline scales by auth state, PRE_AUTH_LIVENESS_TIMEOUT 90s (= PIN_TTL_SECS 60s + margin) pre-auth, 10s post-auth; commits e1c01d1 (RED), 213b8fd (fix), fead00a (docs); regression test pre_auth_silence_survives_pin_entry green"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "UAT Test 5 re-run (the 04-10 fix, on device): pair, lock a modifier (long-press Shift chip so it is physically held server-side), then kill the phone's WiFi abruptly (airplane mode / radio off — no graceful close). Watch the PC."
    expected: "The PC releases Shift within ~10 seconds of the kill (LIVENESS_TIMEOUT), not after OS-TCP-timeout minutes; on reconnect the chips are reset and typing behaves normally"
    why_human: "The regression test simulates the half-open socket byte-for-byte on loopback, but the real radio-kill path (Android WiFi stack, router behavior) is exactly what the original UAT caught that automation missed — the fix must be confirmed on the same hardware path that exposed the gap"
  - test: "Slow-PIN pairing sanity check (the CR-01 fix, on device): forget the pairing (or use a fresh install), start pairing, and deliberately wait 20-30 seconds before typing the 6-digit PIN, then complete pairing on that same connection"
    expected: "Pairing completes normally — the session is NOT dropped during the pause (no transport error, no new challenge/PIN churn); PIN entry has the full 60s window"
    why_human: "The paused-clock test proves the server holds the session 30s pre-auth, but the end-to-end pairing UX (client backoff/redial behavior around a slow human) needs one real-device confirmation since the CR-01 failure mode was invisible to the original suite"
---

# Phase 4: Trackpad & Keyboard — Verification Report (Re-verification after 04-10 + review CR-01 fix)

**Phase Goal:** The phone is a genuinely usable daily mouse and keyboard — trackpad feel (raw Listener classifier, acceleration, momentum, drag lock) and typing fidelity (IME diff-ops, special rows, sticky modifiers, server-side autorepeat) match a real laptop, not a toy
**Phase User Story (from all PLANs, MVP mode):** As a laptop owner, I want to use my phone as a precise mouse and full keyboard for my Windows laptop, so that it replaces a real trackpad and keyboard — not a toy.
**Verified:** 2026-07-10T10:03:29Z
**Status:** passed — all 5 roadmap success criteria verified; on-device UAT complete including both post-fix re-checks (WiFi-kill stuck-key re-test PASSED, slow-PIN pairing PASSED, 2026-07-10)
**Re-verification:** Yes — third pass. Initial (gaps_found 3/5) → gap plans 04-07/08/09 → second pass (human_needed 5/5) → on-device UAT (4/5, Test 5 MAJOR gap) → gap plan 04-10 + review CR-01 follow-up → this pass.

## Re-verification Summary

The prior verification passed 5/5 automated criteria with four deferred on-device gates. UAT then ran all four on real hardware: Tests 1-4 passed outright (cold start, ballistics/multi-monitor, full gesture set vs Remote Mouse, IME fidelity + no-replay), and Test 5 passed everything except its abrupt-disconnect leg — killing WiFi while Shift was locked left the key held on the PC. Root cause (confirmed by code read, not SUMMARY): CONN-07 `release_all` is straight-line code after the read loop, and a half-open TCP connection (no FIN/RST) never makes `stream.next()` yield — `run_session` had no liveness mechanism.

Gap plan 04-10 closed it; a same-session code review then caught that the fix itself broke pairing (unconditional 10s deadline vs the client's post-auth-only ping cadence), which was fixed by scaling the deadline by auth state. Every claim below was independently confirmed in the code and by running the suite — not taken from SUMMARY.md.

| Gap | Fix | Commits | Independently confirmed in code | Regression test |
|-----|-----|---------|--------------------------------|-----------------|
| UAT Test 5 (MAJOR): half-open WiFi kill leaves held key stuck until OS TCP timeout | 04-10: `LIVENESS_TIMEOUT` (10s) + `last_inbound: tokio::time::Instant` + `sleep_until` select! branch → `break 'read` onto the EXISTING CONN-07 cleanup | baff15a (RED), d269c05 (fix), 71e5f59 (docs) | ✓ session.rs:60 (const, doc-commented with the 250ms/2s client cadence rationale — verified against latency_probe.dart:91,93 defaults), :111 (`last_inbound`), :127-131 (deadline branch breaking `'read`), :160 (refresh on EVERY `Some(Ok(m))` BEFORE the frame-type match so Text/Binary/WS-control all count; pause branch deliberately does not refresh), :217 (unchanged straight-line `release_all` — no new cleanup code). tokio Instant (not std) per the paused-clock house style (:23-26) | integration.rs:346 `half_open_silence_releases_held_input` — KeyDown barrier under real time, `pause()`, socket kept ALIVE and silent (never dropped — dropping is the graceful FIN path the sibling test at :284 covers), KeyUp asserted within a 60s virtual bound (comment pins the >10s coupling), `resume()` + real-time 2s session-end check per plan-checker flake note. PASSING |
| Review CR-01 (Critical): unconditional 10s deadline killed pre-auth sessions mid-PIN-entry (client pings only start post-auth; server's own PIN window is 60s) | Deadline scales by auth state inside the same branch: `Authed` → 10s (UAT Test 5 contract — held input only exists post-auth); pre-auth → `PRE_AUTH_LIVENESS_TIMEOUT` 90s | e1c01d1 (RED), 213b8fd (fix), fead00a (docs) | ✓ session.rs:71 (`PRE_AUTH_LIVENESS_TIMEOUT = 90s`, doc comment cites `PIN_TTL_SECS` — verified: pin.rs:13 `= 60`, so 90 = window + margin, deadline can never race a still-valid PIN), :127-131 (`if ctx.auth_state == AuthState::Authed` selector). T-04-10-02 squatter hygiene relaxed 10s → 90s, still bounded | integration.rs:427 `pre_auth_silence_survives_pin_entry` — hello/challenge to AwaitingAuth, 30s paused-clock silence (past the old 10s kill, inside both the 60s PIN window and the 90s deadline), then PIN pairing completes on the SAME connection (`pairOk` asserted). PASSING |

**Commit and scope audit:** all 6 claimed commits exist at the top of history in RED→GREEN→docs order (baff15a → d269c05 → 71e5f59 → [re-review 86cd9f5] → e1c01d1 → 213b8fd → fead00a); working tree clean (code on disk = HEAD). `git diff --name-only ade8536..HEAD -- app server protocol` = exactly `server/server-core/src/transport/session.rs` + `server/server-core/tests/integration.rs`. Zero changes under app/, protocol/, or server-windows/ — every Flutter-side result (238/238 tests, byte-identical 39-key vocabulary, hot-path/redaction/purity invariants, `flutter analyze` clean) and the server-windows 10/10 stand by immutability.

## User Flow Coverage (MVP mode)

| Step | Expected | Evidence in codebase | Status |
|------|----------|---------------------|--------|
| Move a finger on the trackpad | PC cursor moves 1:1 with acceleration | Listener → GestureClassifier → TrackpadDriver → sendMove 0x01 → absolute SendInput; UAT Test 2 PASSED on device (ballistics + multi-monitor) | ✓ |
| Tap / two-finger tap / L-M-R bar | Left, right, explicit clicks | Click intents → ClickMsg → router → enigo; UAT Test 3 PASSED on device (initial failure was a stale APK, diagnosed and cleared) | ✓ |
| Two-finger scroll, momentum, post-lift | Full-rate scroll incl. after one-finger lift | Live-pointer-count divisor (04-09); UAT Test 3 PASSED including the WR-04 path | ✓ |
| Long-press drag, drag lock | Pill shows, tap drops, edge drags work | Drag intents + ValueNotifier pill; UAT Test 3 PASSED | ✓ |
| Type with the phone IME across a disconnect | Exact text on PC, no replay | Atomic producer+controller reset (04-07); UAT Test 4 PASSED incl. CR-01 no-replay on device | ✓ |
| Hold keys, rollover, combos | Autorepeat, rollover releases all, Win+D | Set-based held tracking (04-08); UAT Test 5 PASSED the Win+D / Ctrl+Right / rollover legs on device | ✓ |
| Kill WiFi while a modifier is locked | PC releases the key within ~10s | Liveness deadline → CONN-07 (04-10), regression-tested; on-device re-run PENDING (human gate 1) | ✓ code / human re-test pending |
| Pair with a slow human PIN entry | Session survives the pause, pairing completes | Auth-state-scaled deadline (CR-01 fix), regression-tested; on-device sanity check PENDING (human gate 2) | ✓ code / human check pending |

## Goal Achievement

### Observable Truths (roadmap Success Criteria — the contract)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Full gesture set: accelerated move, tap=left, two-finger tap=right, L/M/R buttons, momentum scroll w/ instant touch-stop, long-press drag with drag lock | ✓ VERIFIED | Unchanged since prior verification (zero app/ diffs); now ALSO confirmed on device — UAT Tests 2+3 passed against the Remote Mouse benchmark |
| 2 | IME typing (autocomplete, emoji, backspace) produces exactly the same text on the PC | ✓ VERIFIED | Unchanged code; UAT Test 4 passed on device including multi-codepoint emoji, rapid backspace, and the CR-01 (IME) no-replay path |
| 3 | F1–F12, numpad, nav cluster all work from toggleable key rows | ✓ VERIFIED | Unchanged code; 39-key vocabulary byte-identical across languages (carried); keymap coverage tests green in this run (server 10/10 windows-side) |
| 4 | Sticky modifiers show held state, send combos, auto-reset, reset safely on disconnect | ✓ VERIFIED | UAT Test 5 passed Win+D auto-reset and locked-Ctrl combos on device. The "reset safely on disconnect" leg — which UAT FAILED under abrupt WiFi loss — is now closed: liveness deadline (session.rs:127-131) makes CONN-07 release_all (:217) reachable under half-open TCP; `half_open_silence_releases_held_input` green. On-device re-test is human gate 1 |
| 5 | Held keys autorepeat server-side and stop immediately on release | ✓ VERIFIED | UAT Test 5 passed the hold/autorepeat/stop and CR-02 rollover legs on device; the stuck-key-on-silent-disconnect tail is closed by the same 04-10 mechanism (KEY-04 hardening) |

**Score:** 5/5 roadmap success criteria verified

### Plan 04-10 Must-Have Truths

| Truth | Status | Evidence |
|-------|--------|----------|
| A session that stops receiving inbound frames (half-open TCP) releases ALL held keys/buttons within the liveness deadline | ✓ VERIFIED | session.rs deadline branch → break 'read → drain-based idempotent release_all; `half_open_silence_releases_held_input` asserts KeyUp AND session termination; ran green in this verification |
| Every graceful teardown path still releases held input exactly as before | ✓ VERIFIED | All 10 integration tests green including `disconnect_mid_drag_releases_held_input` (FIN/RST sibling), oversize, version-reject, pause paths; full suite has zero regressions |
| A healthy connected client is NEVER disconnected by the liveness deadline | ✓ VERIFIED | 10s ≥ 5× the slowest healthy post-auth cadence (idlePingIntervalMillis = 2000, latency_probe.dart:93); pre-auth silence (the CR-01 hole in the original claim) now gets 90s > the 60s PIN window; `pre_auth_silence_survives_pin_entry` green; walking-skeleton and reconnect tests green |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `server/server-core/src/transport/session.rs` | `LIVENESS_TIMEOUT` const + `last_inbound` tracking + `sleep_until` liveness branch in run_session's select! | ✓ VERIFIED | Const :60 (10s) + `PRE_AUTH_LIVENESS_TIMEOUT` :71 (90s, CR-01); branch :127-131; refresh :160; module doc extended to name the half-open leg (:4-6); no logging of secrets (T-01-31 doc intact, no log calls in file) |
| `server/server-core/tests/integration.rs` | `half_open_silence_releases_held_input` regression test | ✓ VERIFIED | :346, substantive (69 lines): real-time KeyDown barrier, paused-clock silent wait, KeyUp assertion, real-time session-end check; PLUS `pre_auth_silence_survives_pin_entry` :427 (CR-01) |
| All 18 prior-verification artifacts (server-windows executors, classifier, tuning, driver, IME stack, key rows, FSM, chips…) | Unchanged | ✓ VERIFIED (carried) | Zero diffs outside the two files above since ade8536 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| run_session liveness branch (session.rs:127-131) | CONN-07 `ctx.held.release_all` (session.rs:217) | `break 'read` on deadline expiry — cleanup is the EXISTING unskippable straight-line path, no new cleanup code | ✓ WIRED | Break target confirmed; release_all is drain-based and idempotent (held.rs contract) so the pause-branch overlap is a no-op |
| integration.rs half-open test | `CallLog::wait_for` (executors/mock.rs) | Notify-driven KeyUp assertion under paused tokio time | ✓ WIRED | :357-366 (KeyDown barrier), :384-393 (KeyUp); no polling loops |
| Deadline selector | `ctx.auth_state` (dispatch::AuthState) | `if ctx.auth_state == AuthState::Authed` inside the sleep_until expression | ✓ WIRED | session.rs:127; the auth-state transitions (:279, :318, :340) are the same FSM the handshake owns — no new state introduced |
| All 19 prior links (client pipelines, router, executors, vocabulary mirror) | — | — | ✓ WIRED (carried) | Files unchanged; suite green |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| Liveness deadline | `last_inbound` | Refreshed on every `Some(Ok(m))` from `stream.next()` — real inbound socket bytes | Yes — Text, Binary, AND WS control frames count; pause toggles do not | ✓ FLOWING |
| CONN-07 release | `ctx.held` | HeldInput populated by router on key/drag downs, drained by release_all | Yes — test observes real KeyUp calls on the mock executor | ✓ FLOWING |
| All prior traces (moves, scroll, TextMsg, KeyMsg, server injection) | — | — | Unchanged | ✓ FLOWING (carried) |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full server workspace suite (run once) | `cargo test` in server/ | 115/115: 91 (server-core unit) + 4 (fixtures) + 10 (integration, incl. BOTH new regression tests by name) + 10 (server-windows) + 0 doc | ✓ PASS |
| Half-open regression test present and passing | integration run output | `test half_open_silence_releases_held_input ... ok` (suite finished in 0.22s — paused-clock design works, no real 60s wait) | ✓ PASS |
| Pre-auth PIN-entry regression present and passing | integration run output | `test pre_auth_silence_survives_pin_entry ... ok` | ✓ PASS |
| All 6 claimed commits exist, RED precedes GREEN | `git log` inspection | baff15a→d269c05→71e5f59 and e1c01d1→213b8fd→fead00a in order; tree clean | ✓ PASS |
| Blast radius | `git diff --name-only ade8536..HEAD -- app server protocol` | Exactly session.rs + integration.rs; zero app/protocol/server-windows changes | ✓ PASS |
| Flutter suite (238/238), analyze, vocabulary diff | Not re-run — zero app/ files changed since the prior verification's green run | Results stand by immutability | ✓ PASS (carried) |
| Deadline-rationale anchors | grep pin.rs / latency_probe.dart | `PIN_TTL_SECS = 60` (pin.rs:13); `pingIntervalMillis = 250` / `idlePingIntervalMillis = 2000` (latency_probe.dart:91,93) — the doc-comment math in session.rs is true | ✓ PASS |

### Probe Execution

SKIPPED — no `scripts/*/tests/probe-*.sh` probes exist in this project and no plan declares any.

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| PAD-01 | 04-01, 04-03, 04-04 | One-finger move, velocity acceleration, sub-pixel accumulation | ✓ SATISFIED | Carried + UAT Tests 2-3 device pass |
| PAD-02 | 04-02, 04-03, 04-04 | Tap = left, two-finger tap = right, L/M/R buttons | ✓ SATISFIED | Carried + UAT Test 3 device pass |
| PAD-03 | 04-02, 04-03, 04-04, 04-09 | Two-finger scroll, momentum, instant touch-stop | ✓ SATISFIED | Carried + UAT Test 3 device pass incl. WR-04 path |
| PAD-04 | 04-02, 04-03, 04-04 | Long-press drag with drag lock | ✓ SATISFIED | Carried + UAT Test 3 device pass |
| KEY-01 | 04-02, 04-05, 04-07 | IME typing incl. autocomplete + backspace | ✓ SATISFIED | Carried + UAT Test 4 device pass incl. no-replay |
| KEY-02 | 04-02, 04-06 | F1–F12, numpad, nav cluster | ✓ SATISFIED | Carried; vocabulary byte-identical; keymap tests green |
| KEY-03 | 04-02, 04-06 | Sticky modifiers, combos | ✓ SATISFIED | Carried + UAT Test 5 device pass (Win+D, locked Ctrl) |
| KEY-04 | 04-02, 04-06, 04-08, **04-10** | Server-side autorepeat, stops on release, held keys never stuck | ✓ SATISFIED | UAT Test 5 device pass for autorepeat/rollover; the abrupt-disconnect stuck-key tail closed by 04-10 (liveness → CONN-07), regression-tested; on-device re-test is human gate 1 |

**Orphaned requirements:** None. All 8 phase-4 IDs are claimed by plans and marked Complete in REQUIREMENTS.md (lines 122-130) — accurate given this verification.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | TBD/FIXME/XXX/TODO/HACK/PLACEHOLDER in server-core (incl. both modified files) | — | None found (fresh grep, zero matches) |
| app/remote_control/lib/net/connection_service.dart | 259-266, 310-353, 547-550 | Reliable queue accumulates during terminal-disconnected states and survives target switches (re-review WR-01; matches the UAT "minor" offline-typing observation) | ⚠️ Warning | Connection-layer, outside phase-4 must-haves; UAT routed it to backlog/next-phase-planning as a design decision (keep-lossless vs drop-for-predictability) |
| server/server-core/src/transport/session.rs | 174, 222 | `tx.send(frame).await` inside the read arm can starve the liveness branch if the peer stops draining its socket; `write_task.await` at teardown can block on a half-open peer (re-review WR-02) | ⚠️ Warning | Pre-existing structure (write path, not the read path 04-10 fixed); held input IS released before the teardown await; tracked in 04-REVIEW.md, explicitly out of 04-10 scope per review routing |
| lib/settings/sensitivity.dart, lib/keyboard/key_rows.dart | — | Async prefs load can clobber a user set() (carried WR) | ⚠️ Warning | UI/storage disagreement until restart; carried |
| — | — | UI polish: owner verdict "the ui is horrible" (UAT Test 3 note) | ℹ️ Info (cosmetic per UAT triage) | Functionality verified; routed to a UI review/polish pass (/gsd-ui-review) — does not block the phase goal, which UAT itself marked non-blocking |

No logging of PIN/token/text anywhere in session.rs (T-01-31 upheld — the new code adds no log sinks). The review's new CR-01 is resolved in-phase (`resolved_in_phase` in 04-REVIEW.md frontmatter, commit 594331d); remaining review findings are warnings/infos, none blocking phase-goal truths.

### Human Verification Required

The prior verification's four deferred gates were executed as on-device UAT (4/5 passed — see 04-UAT.md). What remains is narrow: re-test the two fixes that landed after UAT, on the same hardware path that exposed the original gap.

#### 1. WiFi-kill stuck-key re-test (UAT Test 5 re-run — the 04-10 fix)

**Test:** Pair, long-press-lock Shift (chip shows locked, key held server-side), then kill the phone's WiFi abruptly (airplane mode / radio off — not an app close). Watch the PC.
**Expected:** The PC releases Shift within ~10 seconds (LIVENESS_TIMEOUT), not minutes; on reconnect, chips are reset and input is normal.
**Why human:** The regression test proves the half-open shape on loopback, but the real Android-radio-kill path is precisely what automation missed the first time.

#### 2. Slow-PIN pairing sanity check (the CR-01 fix)

**Test:** From an unpaired state, start pairing and deliberately wait 20-30 seconds before entering the 6-digit PIN; complete pairing.
**Expected:** The session survives the pause — no transport error, no challenge/PIN churn; pairing completes on the first connection.
**Why human:** Confirms the end-to-end pairing UX around a slow human (client backoff/redial interplay), which the paused-clock server test cannot cover.

### Gaps Summary

None remaining. The single UAT MAJOR gap (Test 5: half-open WiFi kill preserves held input) is closed by a named mechanism — `LIVENESS_TIMEOUT` (10s post-auth) driving the pre-existing straight-line CONN-07 `release_all` — and the fix's own critical regression (review CR-01: pre-auth PIN-entry sessions killed at 10s) is closed by the auth-state-scaled deadline (90s pre-auth, anchored to the 60s PIN TTL). Both are locked by socket-level regression tests inside a 115/115-green server suite; the client side is untouched (238/238 Flutter tests stand by immutability); blast radius is exactly the two declared files.

UAT's two non-blocking observations (UI polish verdict — cosmetic; offline-typed text flushing from the reliable FIFO — minor design decision) are routed to backlog per the UAT triage and do not gate the phase goal.

Status is `human_needed` rather than `passed` solely because the two fixes above must be confirmed once on real hardware — the WiFi-kill re-run (the exact scenario automation missed before) and one slow-PIN pairing check. Automated verification is exhausted; all five roadmap success criteria verify programmatically and four of five were already confirmed on device.

---

_Verified: 2026-07-10T10:03:29Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification after gap-closure plan 04-10 and review CR-01 follow-up_
