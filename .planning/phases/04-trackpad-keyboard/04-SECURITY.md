---
phase: 04
slug: trackpad-keyboard
status: blocked
threats_open: 2
asvs_level: 1
created: 2026-07-10
---

# Phase 04 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| client move frame → OS cursor injection | Authed session 0x01 deltas drive real SendInput | pointer deltas (low sensitivity) |
| client key/click/text frame → OS input injection | Authed click/key/text drives enigo SendInput into focused window | keystrokes, clicks (high impact) |
| touch input → wire frames | Raw touches become volatile 0x01/0x02 frames + reliable click/drag messages | gestures (low sensitivity) |
| device IME → text frames → OS typing | Everything typed (incl. autocomplete output) crosses as `text {bs, ins}` | typed text incl. passwords (high sensitivity) |
| app-drawn keys → key frames → OS keystrokes | Special keys, combos, held modifiers become real OS input (incl. Win+D, Ctrl+Alt+Del) | key codes (high impact) |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-04-01 | DoS / Tampering | input_thread.rs absolute inject + click/key/text arms | mitigate | `normalize_virtual` clamps to virtual screen (input_thread.rs:121, property-tested incl. i32::MIN/MAX); GetCursorPos failure drops frame; all 12 enigo calls `let _ =` — never panic | closed |
| T-04-02 | Tampering / Input Validation | keymap.rs map_key + kClientKeyCodes mirror | mitigate | Unknown code → None → silent whole-command drop (keymap.rs:128, input_thread.rs:240); coverage tests both sides; mirror verified byte-identical 39/39 this audit | closed |
| T-04-03 | Information Disclosure | Cmd::Type arm + ImeDiffProducer/HiddenTextInput | mitigate | Redaction verified (zero typed-text logging either side; ExcludeSemantics at hidden_text_input.dart:79) — BUT CR-01: one-sided `_imeProducer.reset()` (trackpad_screen.dart:136) desyncs producer from controller; first post-reconnect keystroke replays ALL pre-disconnect typed text (potentially a password) into the new session via guaranteed-delivery sendReliable | **open** |
| T-04-04 | DoS local (stuck input) | held key/button, locked modifiers, held caps | mitigate | Declared mitigations present (session.rs:86,158 release_all; D-12 client reset; enigo release_keys_when_dropped) but all fire only at session end — CR-02: single `_heldCode` slot (keyboard_panel.dart:105) swallows first key's `up` on rollover; key stays autorepeating for remainder of live session. Fold IN-04 (key_rows.dart:409-413 mid-press `enabled` flip) into same fix | **open** |
| T-04-05 | Spoofing / EoP | pre-auth input frames | mitigate | `shouldSendVolatile()` gates sendMove+sendScroll (connection_service.dart:293,303); sendReliable auth-gated bounded FIFO ≤10 (send_policy.dart:38-52); server router.rs:64-77 pre-auth + pause gates | closed |
| T-04-06 | DoS local | fling/momentum loop, long-press timers | mitigate | StopFlingIntent unconditionally first on pointer-down (gesture_classifier.dart:283); generation-guarded timers, cancel on reset/dispose, self-stop below kMomentumStopVelocity (trackpad_driver.dart:119-189) | closed |
| T-04-07 | Tampering (stale held state) | drag-lock across disconnect | mitigate | driver.reset() on ChipStatus.disconnected (trackpad_screen.dart:133-135) clears client state, sends nothing; server release_all unconditional on session end | closed |
| T-04-08 | DoS | oversized ins / runaway bs | mitigate | MAX_BS=10000 checked before executor with err reply (router.rs:22,124-133); MAX_WS_MESSAGE_BYTES=65536 at accept (listener.rs:17) | closed |
| T-04-SC | Supply Chain | dependencies | accept | No new packages any plan; only feature flags `Win32_UI_Input_KeyboardAndMouse` + `Win32_UI_WindowsAndMessaging` on already-locked windows 0.62 (commit b1816f9); pubspec.yaml untouched | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-04-01 | T-04-SC | No new packages this phase; only Win32 feature flags enabled on the already-vetted, spec-locked windows 0.62 dependency (commit b1816f9) | owner (plan-time disposition) | 2026-07-10 |

*Accepted risks do not resurface in future audit runs.*

---

## Unregistered Flags (audit 2026-07-10 — no threat-register mapping)

| Flag | Location | Class | Note |
|------|----------|-------|------|
| WR-01 | connection_service.dart:360-420 | spoofing-adjacent | No dial-generation guard; concurrent dials can bind session to wrong target. Register as Phase-3-scoped threat or fix with `_dialGen` idiom |
| WR-02 | connection_service.dart:327-346 | latent resource DoS | dispose() doesn't invalidate pending backoff timers → post-dispose redial opens unclosed socket |
| IN-01 | server-core/src/auth/mod.rs:31,84-97 | misleading dead state | `active_nonce` written never read; actual replay enforcement verified on session's per-session nonce — no hole today |
| IN-02 | key vocabulary | hardening | Per-side coverage tests but no cross-language shared-fixture equality test; mirrored typo would pass both suites (lists verified identical today) |
| IN-03 | connection_service.dart:80-96 | minor resource growth | One leaked HttpClient per dial across backoff episodes |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-10 | 9 | 7 | 2 | gsd-security-auditor |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [ ] `threats_open: 0` confirmed — **blocked: T-04-03 (CR-01), T-04-04 (CR-02) open pending gap closure**
- [ ] `status: verified` set in frontmatter

**Approval:** pending — fix CR-01/CR-02 (see 04-REVIEW.md for patches + regression tests), then re-run `/gsd-secure-phase 4`
