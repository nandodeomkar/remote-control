---
phase: 3
slug: discovery-pairing-connection
status: draft
nyquist_compliant: false
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
| *(filled by planner — one row per task)* | | | | | | | | | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*(Planner fills: beacon codec fixture tests, reconnect FSM test stubs, secure-store fake, MethodChannel fake for MulticastLock.)*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Beacon received on owner's Xiaomi/HyperOS device | CONN-01 | OEM broadcast filtering is device-dependent | Run server, open app on phone, device appears in list within ~4s |
| PIN visible in Windows notification | CONN-02 | Toast rendering is OS-side | Trigger pairing, observe toast (or console fallback) |
| ws:// still connects after cleartext-config swap | CONN-03/05 | Android network-security-config applies at runtime on device | On-device connect smoke test after manifest change |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
