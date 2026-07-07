---
phase: 1
slug: protocol-contract-server-core
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-07
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (Rust workspace) + dart test (pure Dart package) |
| **Config file** | none — Wave 0 installs (server/Cargo.toml workspace, app/packages/remote_protocol/pubspec.yaml) |
| **Quick run command** | `cargo test -p server-core` |
| **Full suite command** | `cargo test --workspace && (cd app/packages/remote_protocol && dart test)` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p server-core`
- **After every plan wave:** Run full suite (Rust workspace + Dart package)
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (populated by planner) | | | | | | | | | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Rust workspace scaffold with `server-core` crate and test harness (`cargo test` runs)
- [ ] Pure Dart package scaffold with `dart test` runner (gated on Dart SDK setup task)
- [ ] Shared fixture loader helpers in both test suites pointing at `protocol/fixtures/`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Dart/Flutter SDK installation | — | Environment setup on owner's machine; not scriptable in CI | Install Flutter SDK (bundles Dart), verify `dart --version` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
