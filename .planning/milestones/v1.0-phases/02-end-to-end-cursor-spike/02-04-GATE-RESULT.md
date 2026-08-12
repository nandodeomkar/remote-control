---
phase: 02-end-to-end-cursor-spike
plan: 04
gate: PAD-05 hard transport gate
verdict: PASS
measured_p50_ms: 6
measured_p95_ms: 10
tested: 2026-07-08
device: 25080RABDI (Xiaomi/HyperOS, Android 16 / API 36)
server: server-windows on Windows 11, LAN 192.168.29.42:17777
network: real WiFi (phone 192.168.29.18 <-> laptop 192.168.29.42), same subnet
---

# Phase 02 Hard-Gate Result — End-to-End Cursor Spike

**VERDICT: PASS.** The make-or-break `<30ms` WebSocket-only transport budget is
met on real WiFi by a wide margin. The transport risk Phase 02 exists to retire
is **retired** — the roadmap's UDP-mouse-channel reconsideration is NOT triggered.

## Measurement setup

- Real Android phone (Xiaomi 25080RABDI, Android 16) on real WiFi, connected to
  the `server-windows` binary on the Windows 11 laptop over the LAN.
- Full real handshake: manual IP entry → `connectNoDelay` → hello → challenge →
  PIN pair → Authed. Cursor driven by finger drags via the `Listener` trackpad →
  `MoveSender` → 9-byte binary move frames. Latency read from the on-device HUD
  (interleaved-ping-under-move-load RTT, p50/p95).

## Criteria judgments

| # | Criterion | Result | Notes |
|---|-----------|--------|-------|
| 1 | Visually instant, no perceptible lag | **PASS** | Cursor tracks the finger with no perceptible lag |
| 2 | Move-frame E2E latency p95 < 30ms (under load) | **PASS** | Measured **p50 = 6ms, p95 = 10ms** — ~3× under budget |
| 3 | No 40–200ms hitches on slow precise movement | **PASS*** | Smooth; no hitches. *See accel note below |
| 4 | Slow diagonal tracks smoothly (sub-pixel + DPI) | **PASS*** | Smooth, no drift/stair-step. *See accel note below |

TCP_NODELAY: active both ends (server enigo path proven in 02-01; client
`connectNoDelay` seam proven in 02-02); the sub-6ms p50 under continuous load is
consistent with Nagle disabled — no traffic-pattern-dependent hitching observed.

## Known issue discovered by the gate (does NOT block the transport verdict)

**Windows pointer acceleration eats slow relative deltas.** With Windows
"Enhance pointer precision" (Settings → Mouse → Pointer Options) ENABLED — the
Windows default — slow/small finger drags produced NO cursor movement while fast
drags worked. Disabling "Enhance pointer precision" made criteria 3 and 4 pass
cleanly.

- **Cause:** the server injects relative motion (`MOUSEEVENTF_MOVE` via enigo
  `Coordinate::Rel`), which Windows pointer ballistics scales down at low speed —
  small integer deltas emitted by the sub-pixel accumulator get curved toward 0.
  This is an OS-injection-fidelity issue, NOT a transport/latency issue and NOT a
  bug in the sub-pixel accumulator (which correctly carries fractions; the loss is
  downstream at the OS ballistics curve).
- **Workaround (used to pass the gate):** disable "Enhance pointer precision".
- **Recommended real fix:** inject **absolute** motion (GetCursorPos +
  accumulated delta → normalized absolute SendInput / enigo `Coordinate::Abs`),
  which bypasses pointer ballistics for true 1:1 tracking regardless of the OS
  setting. Watch the multi-monitor / virtual-desktop normalization edge case.
- **Scope call:** the transport gate PASSES with the workaround. The accel fix is
  cursor-*feel* fidelity — a natural fit for Phase 4 (Trackpad & Keyboard,
  "match a real laptop") unless fixed as a Phase-02 follow-up. Tracked as a
  known issue.

## Outcome

- Phase 02 hard gate: **CLEARED.** Transport is proven (`ws://` + TCP_NODELAY,
  p95 = 10ms on real WiFi). Phase 3 may proceed.
- Follow-up (non-blocking): server-side absolute-positioning fix so slow tracking
  works without disabling Windows pointer acceleration.
