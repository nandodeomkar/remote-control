# Phase 2: End-to-End Cursor Spike - Context

**Gathered:** 2026-07-07
**Status:** Ready for planning

<domain>
## Phase Boundary

Build the thinnest REAL vertical slice that moves the Windows cursor from a finger on the phone: a Flutter app scaffold with a bare trackpad surface → WebSocket (reusing Phase 1 `server-core`) → a new `server-windows` binary with an enigo-backed `MouseKeys` executor → the actual OS cursor moves. Prove PAD-05: cursor is visually instant on real WiFi with measured move-frame end-to-end latency < 30ms, no 40–200ms hitches (TCP_NODELAY both ends), and smooth diagonal tracking (server-side sub-pixel accumulation + DPI awareness).

This is a **risk-retirement spike** and a **hard gate**: if the <30ms budget cannot be met on real WiFi, the transport decision reopens (UDP mouse channel behind the existing transport abstraction) before any later phase proceeds.

**In scope:** Flutter app scaffold, minimal trackpad gesture→move-frame path, `server-windows` crate + enigo mouse executor (move + scroll), latency measurement + on-device readout, TCP_NODELAY verification both ends, sub-pixel accumulation, DPI awareness.

**Out of scope:** Full trackpad UX (gestures beyond move/scroll, buttons, haptics), keyboard, control-center features, discovery/beacon UI, polished pairing screens, the dashboard — all later phases. No new wire-protocol changes (Phase 1's contract is frozen).

</domain>

<decisions>
## Implementation Decisions

User was offered all four gray areas (auth scope, cursor feel, latency readout, keep-vs-throwaway) and answered "no preference" — all four delegated to Claude's discretion. Defaults locked below, chosen to match the spike's "thinnest REAL vertical slice" intent, so downstream agents (researcher, planner) don't re-litigate.

### Auth scope
- **D-01:** The spike runs the **real** Phase 1 handshake (hello → challenge → pin/pairOk → auth → authOk), NOT an auth-bypass dev path. `server-core` already enforces auth gating and is fully tested — reusing it exercises the real path for free and adds zero throwaway code to the core. Auth is a one-time handshake and does not affect steady-state cursor latency (measured post-auth on move frames), so keeping it real costs nothing on the measurement.
- **D-02:** Pairing UX in the spike is **minimal**: the tray/console shows the PIN; the app has a bare text field to type it (or a dev-fixed PIN for the owner's own test loop). No polished pairing screens — that's Phase 3.

### Cursor feel
- **D-03:** **Raw 1:1 finger-delta passthrough** — phone sends move frames of raw dx/dy deltas; no sensitivity curve, no acceleration in the spike. Rationale: criteria 2 (true latency) and 3 (no hitches) are cleanest measured on raw deltas; an accel/sensitivity curve is product-polish that would mask the underlying transport behavior. Sensitivity/acceleration is deferred to the real trackpad phase.
- **D-04:** **Server-side sub-pixel accumulation stays** (criterion 4): the enigo executor accumulates the fractional-pixel remainder across frames so slow diagonal movement tracks smoothly without drift or stair-stepping. This is accuracy plumbing, not "feel," and is load-bearing — keep it. DPI awareness (per-monitor DPI, `SetProcessDpiAwarenessContext` or equivalent) is in scope so deltas map to the right physical pixels.

### Latency readout
- **D-05:** Latency is surfaced **live on the phone (an on-device HUD)** so "visually instant" and the number are both verified on the real device over real WiFi — not just in a desktop log. Server-side logging of the measurement is also kept for the record.
- **D-06:** Measured on **actual move-frame round-trips (echo), not ping RTT** (criterion 2 is explicit about this). Spike adds a measurement variant where the phone stamps a send-time, the server echoes it, and the phone computes end-to-end. Exact echo mechanism is left to research/planning — the decision is only that it measures move-frame E2E, displayed live.
- **D-07:** Report **p50 and p95**; treat the gate as **p95 < 30ms** on real WiFi (criterion 3's "no 40–200ms hitches" is a tail-latency concern, so gate on the tail, not just the median). If p95 fails, trigger the roadmap's UDP-channel reconsideration before Phase 3.

### Keep vs throwaway
- **D-08:** Build minimal, but the load-bearing parts are **kept as foundation**, not thrown away: the `server-windows` crate + enigo `MouseKeys` executor (needed by every later phase) and the Flutter app scaffold + bare trackpad surface (Phase 3 grows it). "While the code is small" means build the thin real slice, not build disposable code.
- **D-09:** Only the **latency HUD/measurement mode and any dev-pairing shortcut** are spike-only and removable once the gate passes. Everything else survives into the product.

### Claude's Discretion
- All nine decisions above are Claude-discretion defaults (user had no preference). Planner may refine details (exact crate/file names, measurement mechanism, DPI API choice, whether a dev-fixed PIN or typed PIN) as long as the observable contract holds: real handshake reused, raw 1:1 cursor with server-side sub-pixel + DPI, live on-device move-frame latency readout gated at p95 < 30ms, and the server-windows executor + app scaffold kept as foundation.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design spec (authoritative)
- `docs/superpowers/specs/2026-07-07-remote-control-design.md` — §6 server-core crate boundaries + executor traits (the `MouseKeys` contract the enigo impl fulfills), §5 wire protocol (9-byte binary move/scroll frame format — frozen), plus any performance/latency and DPI/cursor notes. Approved and locked — planning must follow it.

### Phase 1 foundation (build directly on these)
- `.planning/phases/01-protocol-contract-server-core/01-CONTEXT.md` — locked wire decisions (D-01..D-09), monorepo layout, Dart codec home
- `.planning/phases/01-protocol-contract-server-core/01-06-SUMMARY.md` — transport layer: `run(listener, deps)` entry, `set_nodelay(true)` already applied server-side, session task model
- `server/server-core/src/executors/mod.rs` — the `MouseKeys` trait (`move_rel(dx,dy)`, `scroll(dx,dy)`, ...) the new Windows executor implements
- `server/server-core/src/transport/mod.rs` — `run()` signature + `ServerDeps` the `server-windows` binary wires up
- `app/packages/remote_protocol/` — Dart binary/JSON codecs the Flutter app imports via path dependency

### Research (domain pitfalls & stack)
- `.planning/research/PITFALLS.md` — domain pitfalls with phase mapping (Dart TCP_NODELAY plumbing flagged for Phase 2)
- `.planning/research/STACK.md` — enigo version + rationale; web_socket_channel construction
- `.planning/research/ARCHITECTURE.md` — component boundaries, data flow

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `server-core` transport `run(listener, deps)`: server-side `TcpStream::set_nodelay(true)` already applied and proven in Phase 1 — the spike wires a real executor into `ServerDeps` and does NOT re-solve the server-side socket path.
- `MouseKeys` trait: the enigo executor is a new `impl MouseKeys` — mock executors proved the dispatch/routing already calls `move_rel`/`scroll` correctly, so the trait contract is settled.
- `remote_protocol` Dart package: binary move/scroll frame encoders already exist and are fixture-proven — the Flutter app imports them; no codec work needed on the client.

### Established Patterns
- Cargo workspace at `server/` currently has only `server-core`; the spike ADDS `server-windows` as a second workspace member (the design spec's intended split). `server-core` stays OS-agnostic (zero Windows deps — a Phase 1 verified invariant that must not regress).
- Monorepo `app/` currently holds only the pure Dart `remote_protocol` package; the spike ADDS the Flutter app itself alongside it, importing the package via path dependency (Phase 1 D-03).

### Integration Points
- **Dart-side TCP_NODELAY is the known unknown** (STATE.md Phase 2 blocker): `web_socket_channel`'s construction path must be verified to actually set `TCP_NODELAY` on the client socket, or a raw-socket construction used. This is the single highest-risk item for criterion 3 and should be the researcher's first target.
- New `server-windows` binary is the composition root: builds `ServerDeps` with the enigo executor + real socket and calls `server-core::run()`.

</code_context>

<specifics>
## Specific Ideas

No specific "I want it like X" requirements — user delegated all implementation choices. The spike defaults above (thin real vertical slice, raw 1:1 cursor, on-device latency HUD gated at p95<30ms) stand as the working contract.

</specifics>

<deferred>
## Deferred Ideas

- Sensitivity / acceleration curves for cursor movement — deferred to the real trackpad phase (Phase 3+); the spike uses raw 1:1 to keep the latency signal clean.
- Polished pairing/discovery UX (beacon listener, PIN screens, reconnect FSM) — Phase 3 (Discovery, Pairing & Connection).
- Trackpad gestures beyond move/scroll (tap-click, two-finger, drag, buttons, haptics) — later trackpad phase.

None of these were scope creep from the user — they are the natural boundary of a latency-retirement spike.

</deferred>

---

*Phase: 2-End-to-End Cursor Spike*
*Context gathered: 2026-07-07*
