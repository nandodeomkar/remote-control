---
phase: 3
slug: discovery-pairing-connection
status: planned
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-08
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (Rust workspace) + flutter test (Dart) |
| **Config file** | server/Cargo.toml (workspace), app/remote_control/pubspec.yaml |
| **Quick run command** | `flutter test` (app) or `cargo test -p server-core` (server) — scoped to touched side |
| **Full suite command** | `cargo test` (server/) && `flutter test` (app/remote_control/) |
| **Estimated runtime** | ~60 seconds combined |

---

## Sampling Rate

- **After every task commit:** Run the quick command scoped to the touched side
- **After every plan wave:** Run the full suite (both sides)
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 90 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 03-01-T1 | 03-01 | 1 | CONN-01 | T-03-01, T-03-03 | Beacon payload carries only v/app/name/guid/port/proto (key-set test); send errors never kill the loop | unit + fixture | `cd server && cargo test -p server-core beacon` | created in-task | ⬜ pending |
| 03-01-T2 | 03-01 | 1 | CONN-02 | T-03-04 | PIN to stdout+toast only, never through tracing (source assertion) | build + regression | `cd server && cargo build -p server-windows && cargo test --workspace` | ✅ existing suites | ⬜ pending |
| 03-01-T3 | 03-01 | 1 | CONN-02 | T-03-04 | Toast shows PIN; console fallback prints first | manual-only (checkpoint) | — human-verify (notification rendering not CI-testable) | — | ⬜ pending |
| 03-02-T1 | 03-02 | 1 | CONN-03, CONN-04 | T-03-05 | No StartBackoffEffect for any authRejected reason (retry-storm guard) | unit RED (pure FSM) | `flutter test test/reconnect_fsm_test.dart test/send_policy_test.dart` (expected FAIL at commit) | created in-task | ⬜ pending |
| 03-02-T2 | 03-02 | 1 | CONN-03, CONN-04 | T-03-05..08 | noPairing/badMac → ClearToken + needPairing, no retry; volatile never queued | unit GREEN | `cd app/remote_control && flutter test` | ✅ after T1 | ⬜ pending |
| 03-03-T1 | 03-03 | 1 | CONN-03 | T-03-09..11 | PlatformException → unpaired + delete (no crash); token never in prefs JSON | unit RED (fakes) | `flutter test test/device_store_test.dart` (expected FAIL at commit) | created in-task | ⬜ pending |
| 03-03-T2 | 03-03 | 1 | CONN-03 | T-03-09..11 | Secure storage v10 defaults; no deprecated cipher flag (grep) | unit GREEN | `cd app/remote_control && flutter test` | ✅ after T1 | ⬜ pending |
| 03-04-T1 | 03-04 | 2 | CONN-01 | T-03-12 | 512-byte cap before parse; total parse, zero throw paths (grep) | unit + shared fixtures | `flutter test test/beacon_test.dart` | created in-task | ⬜ pending |
| 03-04-T2 | 03-04 | 2 | CONN-01 | T-03-15 | Lock released with socket in stop(); cleartext swapped in one commit | analyze + build | `flutter analyze && flutter test && flutter build apk --debug` | ✅ suites exist | ⬜ pending |
| 03-04-T3 | 03-04 | 2 | CONN-01 | T-03-12..14 | Beacon reception + ws:// cleartext on real device | manual-only (checkpoint) | — human-verify (OEM broadcast filtering + runtime network policy are device-dependent; emulators receive no LAN broadcast) | — | ⬜ pending |
| 03-05-T1 | 03-05 | 3 | CONN-06 | T-03-25 | Dead-connection latch fires once; probe stays timer-free | unit (fake clock) | `flutter test test/latency_probe_test.dart` | ✅ extend existing | ⬜ pending |
| 03-05-T2 | 03-05 | 3 | CONN-03, CONN-04, CONN-05, CONN-06 | T-03-16..20 | Token never in any sink frame; exactly one dial after revoke; RFC1918 guard truth table; single stream listener | unit (FakeWsChannel + fakes) | `cd app/remote_control && flutter test` | created in-task | ⬜ pending |
| 03-06-T1 | 03-06 | 4 | CONN-01 | T-03-22 | GUID-keyed merge bounds state; no per-packet churn | unit (pure model) | `flutter test test/device_list_store_test.dart` | created in-task | ⬜ pending |
| 03-06-T2 | 03-06 | 4 | CONN-01, CONN-05 | T-03-21 | All user copy from connection_copy.dart (no inline literals) | analyze + widget | `flutter analyze && flutter test` | ✅ suites exist | ⬜ pending |
| 03-06-T3 | 03-06 | 4 | CONN-02 | T-03-23, T-03-24 | Raw authFail enums never rendered (negative widget assertion); PIN never logged | widget + unit | `flutter test test/pairing_flow_test.dart` | created in-task | ⬜ pending |
| 03-07-T1 | 03-07 | 5 | CONN-06 | T-03-25 | Chip reads on 500ms throttle only; honest status mapping | widget | `flutter test test/connection_header_test.dart` | created in-task | ⬜ pending |
| 03-07-T2 | 03-07 | 5 | CONN-04 | T-03-26 | Launch kick sends hello+authProof only; keystore failure degrades to unpaired | analyze + test + build | `flutter analyze && flutter test && flutter build apk --debug` | ✅ suites exist | ⬜ pending |
| 03-07-T3 | 03-07 | 5 | CONN-01..06 | T-03-25..27 | Full 7-step E2E incl. revoked-token stop + re-pair | manual-only (checkpoint) | — human-verify (real WiFi churn, server restart, physical device not reproducible in CI) | — | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Test scaffolds are created inside each plan's RED/tdd task (no separate Wave 0 plan needed — every implementation task's `<automated>` command exists by the time it runs):

- [ ] `app/remote_control/test/reconnect_fsm_test.dart` + `test/send_policy_test.dart` — created by 03-02 Task 1 (RED)
- [ ] `app/remote_control/test/device_store_test.dart` — created by 03-03 Task 1 (RED)
- [ ] `app/remote_control/test/beacon_test.dart` — created by 03-04 Task 1 (tdd, tests-first)
- [ ] `app/remote_control/test/connection_service_test.dart` — created by 03-05 Task 2 (tdd, tests-first)
- [ ] `app/remote_control/test/device_list_store_test.dart` — created by 03-06 Task 1 (tdd, tests-first)
- [ ] `app/remote_control/test/pairing_flow_test.dart` — created by 03-06 Task 3 (tdd, tests-first)
- [ ] `app/remote_control/test/connection_header_test.dart` — created by 03-07 Task 1 (tdd, tests-first)
- [ ] `server/server-core/src/transport/beacon.rs` `#[cfg(test)]` — created by 03-01 Task 1
- [ ] `protocol/fixtures/beacon/*.json` (shared Rust/Dart) — created by 03-01 Task 1
- Framework installs: none — both test frameworks already configured and green

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Beacon received on owner's Xiaomi/HyperOS device | CONN-01 | OEM broadcast filtering is device-dependent; emulators receive no LAN broadcast | 03-04 Task 3: `flutter run -t lib/dev/beacon_smoke_main.dart`, device row within ~4s |
| PIN visible in Windows notification | CONN-02 | Toast rendering is OS-side | 03-01 Task 3: run server, observe toast + console + 60s refresh |
| ws:// still connects after cleartext-config swap | CONN-03/05 | Android network-security-config applies at runtime on device (Assumption A2) | 03-04 Task 3 step 4: on-device connect smoke after manifest change |
| WiFi-drop + server-restart recovery, full E2E | CONN-01..06 | Real network churn + physical hardware not reproducible in CI | 03-07 Task 3: 7-step script (discovery, pairing errors, silent reconnect, drop recovery, revoked-token, manual IP, latency header) |
| Server restart forces re-pair (expected, NOT a bug) | CONN-03 | AuthManager hashes are in-memory until Phase 7 (RESEARCH Pitfall 6) | Documented in 03-07 Task 3 step 5 — must not be reported as a regression |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies (checkpoints justified above)
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (RED/tests-first tasks create every suite before or with its implementation)
- [x] No watch-mode flags
- [x] Feedback latency < 90s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** planner, 2026-07-08 (plan set 03-01..03-07)
