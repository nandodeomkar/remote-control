---
phase: 1
slug: protocol-contract-server-core
status: planned
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-07
updated: 2026-07-07
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (Rust workspace) + dart test (pure Dart package) |
| **Config file** | none — Wave 2 installs server/Cargo.toml workspace; Wave 6 installs app/packages/remote_protocol/pubspec.yaml |
| **Quick run command** | `cd server && cargo test -p server-core` |
| **Full suite command** | `cd server && cargo test --workspace` then `cd app/packages/remote_protocol && dart test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p server-core` (Rust tasks) / `dart test` from package root (Dart tasks)
- **After every plan wave:** Run the scoped green set for that wave (see progressive-green note below)
- **Before `/gsd-verify-work`:** Full suite (both commands) must be fully green
- **Max feedback latency:** 60 seconds

**Progressive-green note (red-first by design):** Plan 02 deliberately creates RED suites (fixture harness + walking-skeleton E2E). Green expectations by wave: after Wave 3 — `--test fixtures` fully green, `--lib` auth/dispatch/codec/mock green; after Wave 4 — `cargo test --workspace` fully green; after Wave 6 — `dart test` + `dart analyze --fatal-infos` green. Per-plan verify commands are scoped so each plan's own gate is green at its completion.

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01.T1 | 01 | 1 | CONN-07 (foundation) | T-01-01, T-01-04, T-01-05, T-01-06 | Auth construction + strictness + caps locked in SPEC | source assertion | `grep -c "HMAC key = SHA-256" protocol/SPEC.md` + schema ConvertFrom-Json | created by task | ⬜ pending |
| 01-01.T2 | 01 | 1 | CONN-07 (foundation) | T-01-01, T-01-02 | Independent .NET-computed auth-proof anchor | fixture validation | PowerShell fixture parse + macHex length check | created by task | ⬜ pending |
| 01-01.T3 | 01 | 1 | CONN-07 (foundation) | T-01-06 | Negative fixtures for NaN/short/bad-opcode | fixture validation | PowerShell fixture parse + counts | created by task | ⬜ pending |
| 01-02.T1 | 02 | 2 | CONN-07 | T-01-07..T-01-09, T-01-SC | Contracts force Result-typed decode; hash-only AuthManager API | build + red E2E | `cargo build -p server-core` + `cargo test --test integration` (expect RED) | created by task | ⬜ pending |
| 01-02.T2 | 02 | 2 | CONN-07 | T-01-07 | Fixture harness defines codec "done" | red harness | `cargo test -p server-core --test fixtures` (expect 4 RED) | created by task | ⬜ pending |
| 01-03.T1 | 03 | 3 | CONN-07 (support) | T-01-10 | Strict binary decode (length/opcode/finite) | unit + fixture | `cargo test -p server-core --test fixtures codec_fixtures_mouse_binary` | ✅ (Wave 2) | ⬜ pending |
| 01-03.T2 | 03 | 3 | CONN-07 (support) | T-01-11, T-01-13 | D-05 ignore-unknown + hard-error missing; Unknown-t support | unit + fixture | `cargo test -p server-core --test fixtures codec_fixtures_handshake codec_fixtures_text` | ✅ (Wave 2) | ⬜ pending |
| 01-04.T1 | 04 | 3 | CONN-07 (support) | T-01-14, T-01-15, T-01-19 | PIN 60s/5/lockout/global-cap; constant-time compare; lockout survives sessions | unit (paused time) | `cargo test -p server-core --lib auth::pin` | created by task | ⬜ pending |
| 01-04.T2 | 04 | 3 | CONN-07 (support) | T-01-15..T-01-18 | Hash-only storage; verify_slice CT; CSPRNG nonce/token | unit + fixture | `cargo test -p server-core --test fixtures auth_proof_fixture` | ✅ (Wave 2) | ⬜ pending |
| 01-05.T1 | 05 | 3 | CONN-07 | T-01-24 | Recording mocks enable release-assertions | unit | `cargo test -p server-core --lib executors::mock` | created by task | ⬜ pending |
| 01-05.T2 | 05 | 3 | CONN-07 | T-01-20..T-01-25 | Auth gate, pause gate, bs cap, confirm map, HeldInput/release_all | unit | `cargo test -p server-core --lib dispatch::` | created by task | ⬜ pending |
| 01-06.T1 | 06 | 4 | CONN-07 | T-01-26, T-01-27, T-01-29 | FSM + size caps + nodelay; unconditional cleanup placement | integration | `cargo test -p server-core --test integration walking_skeleton_pair_auth_input` | ✅ (Wave 2) | ⬜ pending |
| 01-06.T2 | 06 | 4 | **CONN-07 (headline)** | T-01-28, T-01-30 | Mid-drag disconnect → ButtonUp; pre-auth/paused socket-level drops | integration | `cd server && cargo test --workspace` (incl. disconnect_mid_drag_releases_held_input) | created by task | ⬜ pending |
| 01-07.T1 | 07 | 5 | CONN-07 (enabler) | T-01-32, T-01-33 | Official-host-only SDK download; user-scope PATH | CLI | `C:/dev/flutter/bin/dart.bat --version \|\| dart --version` | n/a (machine state) | ⬜ pending |
| 01-07.T2 | 07 | 5 | CONN-07 (enabler) | T-01-32 | Human confirms toolchain provenance + fresh-shell PATH | human-action checkpoint | manual: `dart --version` in new terminal | n/a | ⬜ pending |
| 01-08.T1 | 08 | 6 | CONN-07 (support) | T-01-34, T-01-SC | Pure-Dart scaffold; shared-fixture loader (no copies) | red harness | `cd app/packages/remote_protocol && dart pub get && dart test` (expect RED) | created by task | ⬜ pending |
| 01-08.T2 | 08 | 6 | CONN-07 (support) | T-01-34..T-01-36 | Dart strictness parity; authProof anchor; grapheme correctness | unit + fixture | `cd app/packages/remote_protocol && dart test && dart analyze --fatal-infos` | ✅ (T1) | ⬜ pending |
| 01-08.T3 | 08 | 6 | CONN-07 (support) | — | Dormant CI documents both gates (D-01/D-02) | source assertion | PowerShell Select-String on ci.yml + README | created by task | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Wave 0 gaps from RESEARCH are satisfied by Plans 01 and 02 (Waves 1–2) before any implementation plan runs:

- [ ] `protocol/fixtures/**` — shared inputs (Plan 01, Wave 1 — created FIRST)
- [ ] Rust workspace scaffold + `server-core` crate + full API contracts (`cargo test` runs) — Plan 02.T1
- [ ] `server/server-core/tests/fixtures.rs` — Plan 02.T2 (covers SC-1 Rust side)
- [ ] `server/server-core/tests/integration.rs` — Plan 02.T1 (covers SC-2, CONN-07; walking-skeleton red test)
- [ ] Dart SDK install — Plan 07 (Wave 5; gates all Dart tasks)
- [ ] `app/packages/remote_protocol/` scaffold + `test/fixture_test.dart` — Plan 08.T1 (covers SC-1 Dart side)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Flutter/Dart SDK install + fresh-shell PATH | — (enabler for SC-1 Dart half) | Machine-state change (multi-GB download, PATH); human confirms provenance and new-terminal PATH pickup | Plan 07 Task 2 checkpoint: `dart --version` in a NEW terminal, reply "approved" with version output |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies (17 of 18 automated; 1 human-action checkpoint with CLI-verifiable outcome)
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (fixtures → Plan 01; Rust harness → Plan 02; Dart harness → Plan 08.T1 gated on Plan 07)
- [x] No watch-mode flags
- [x] Feedback latency < 60s (auth timing tests use paused tokio time; integration recvs wrapped in 2s timeouts)
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** planned 2026-07-07 — pending execution
