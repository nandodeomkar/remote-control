---
phase: 2
slug: end-to-end-cursor-spike
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-08
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
>
> **This phase is a latency-retirement spike.** Its headline acceptance (move-frame E2E p95 < 30ms on real WiFi) is a **manual on-device measurement** — real-WiFi latency and OS cursor injection are explicitly not CI-testable (design spec §9). Automated tests cover the *plumbing correctness* around the manual gate (accumulator math, TCP_NODELAY factory logic, codec use, percentile math).

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | `cargo test` (built-in) + existing `#[tokio::test]` harness in `server-core` |
| **Framework (Dart/Flutter)** | `flutter test` (default with Flutter 3.44) |
| **Config file** | none custom — Cargo + Flutter defaults |
| **Quick run command (Rust)** | `cargo test -p server-windows` (from `server/`) |
| **Quick run command (Dart)** | `flutter test` (from the Flutter app dir) |
| **Full suite command** | `cd server && cargo test --workspace` then `flutter test` in the app dir |
| **Manual gate** | On-device HUD read on real WiFi, off-charger: p50 + p95 over a sustained slow-diagonal drag; **gate = p95 < 30ms** |
| **Estimated runtime** | ~5s automated (Rust workspace + Flutter unit) |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p server-windows` (accumulator + wiring) or `flutter test` (nodelay factory + move-frame encoder), whichever the task touched
- **After every plan wave:** Run `cargo test --workspace` then `flutter test`
- **Before `/gsd-verify-work`:** Full automated suite green AND the manual on-device p95 < 30ms measurement passes on real WiFi off-charger
- **Max feedback latency:** ~5 seconds (automated)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 2-*-* | sub-pixel accumulator | — | PAD-05 (crit 4) | — | N/A | unit | `cargo test -p server-windows` | ❌ W0 | ⬜ pending |
| 2-*-* | Dart TCP_NODELAY factory | — | PAD-05 (crit 3) | — | N/A | unit | `flutter test` (nodelay_factory_test) | ❌ W0 | ⬜ pending |
| 2-*-* | move-frame sender | — | PAD-05 | — | N/A | unit | `flutter test` (move_sender_test) | ❌ W0 | ⬜ pending |
| 2-*-* | latency HUD percentile math | — | PAD-05 (crit 2) | — | N/A | unit | `flutter test` (percentile_test) | ❌ W0 | ⬜ pending |
| 2-*-* | server-windows composition root | — | PAD-05 | — | server-core stays zero-Windows-deps | integration | existing `server-core` integration suite green with real executor | ✅ (Phase 1) | ⬜ pending |
| 2-*-* | on-device p95 < 30ms gate | — | PAD-05 (crit 1,2,3) | — | N/A | manual | on-device HUD read, real WiFi, off-charger | ❌ manual | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky. Task IDs finalized by the planner; rows track the validation targets the plans must satisfy.*

---

## Wave 0 Requirements

- [ ] `server/server-windows/` sub-pixel accumulator unit test — stream of sub-integer deltas (e.g. 0.4px/frame) sums to the correct integer sequence with carried remainder, no lost fraction, no stair-step (covers crit 4)
- [ ] Dart `nodelay_factory_test` — assert the `connectionFactory` sets `SocketOption.tcpNoDelay` on the client socket (fake/mock socket or loopback server; at minimum unit-test the factory logic) (covers crit 3, server side already proven in Phase 1)
- [ ] Dart `move_sender_test` — assert pointer-move deltas produce correct `encodeMove` byte frames (reuses `remote_protocol`)
- [ ] Dart latency-HUD percentile test — p50/p95 math on a fixed sample set
- [ ] Manual smoke checklist entry: real phone + PC, off-charger, slow diagonal drag, HUD p95 read, 150%-scaled-display DPI check

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cursor visually instant on real WiFi | PAD-05 (crit 1) | Perceptual, real-network only | Move finger on trackpad, observe PC cursor — no perceptible lag |
| Move-frame E2E p95 < 30ms | PAD-05 (crit 2) | Real-WiFi latency not CI-reproducible | Read on-device HUD p50/p95 over a sustained slow-diagonal drag, off-charger; cross-check server log |
| No 40–200ms hitches | PAD-05 (crit 3) | Requires real network + sustained input | Slow precise movement; watch for stalls; confirm TCP_NODELAY active both ends |
| Smooth diagonals, no drift/stair-step | PAD-05 (crit 4) | Perceptual + real DPI | Slow diagonal on a 150%-scaled display; cursor tracks smoothly, lands where expected |

---

## Validation Sign-Off

- [ ] All automatable tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify (excluding the inherently-manual gate task)
- [ ] Wave 0 covers all MISSING references (accumulator, nodelay factory, move sender, percentile math)
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s (automated)
- [ ] Manual on-device gate documented with clear pass/fail (p95 < 30ms) and the UDP-channel fallback trigger
- [ ] `nyquist_compliant: true` set in frontmatter once the planner wires the Wave 0 tests

**Approval:** pending
