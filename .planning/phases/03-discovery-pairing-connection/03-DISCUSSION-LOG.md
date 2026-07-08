# Phase 3: Discovery, Pairing & Connection - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-08
**Phase:** 3-Discovery, Pairing & Connection
**Areas discussed:** Connect flow on launch, Drop/failure UX, Multi-PC memory, Spike cleanup scope (all delegated)

---

## Gray Area Selection

| Option | Description | Selected |
|--------|-------------|----------|
| Connect flow on launch | Auto-reconnect to last PC vs device-list-first on app open | — |
| Drop/failure UX | What the user sees during WiFi drops, backoff, and revoked-token rejection | — |
| Multi-PC memory | Remember one laptop vs multiple paired PCs with a switcher | — |
| Spike cleanup scope | Fate of D-09 removables: latency HUD, PIN console shortcut, manual-IP screen | — |

**User's choice:** "[No preference]" — no areas selected for interactive discussion; all four delegated to Claude's discretion (same pattern as Phases 1 and 2).
**Notes:** Claude locked defaults for all four areas in CONTEXT.md (D-01..D-10) so downstream agents don't re-litigate.

---

## Todo Cross-Reference

| Option | Description | Selected |
|--------|-------------|----------|
| Keep for Phase 4 (Recommended) | Leave pointer-injection todo pending; natural home is Phase 4 cursor-feel work | ✓ |
| Fold into Phase 3 | Add to Phase 3 scope despite being unrelated to connection work | |

**User's choice:** Keep for Phase 4.
**Notes:** Todo "Absolute pointer injection so slow drags survive Windows pointer acceleration" keyword-matched Phase 3 at score 0.6 (noise: "windows", "phase", "gate"). Recorded under Reviewed Todos (not folded) in CONTEXT.md.

## Claude's Discretion

All four gray areas: connect flow (auto-reconnect + device-list fallback), drop/failure UX (non-blocking banner, transport-retry/auth-stop), multi-PC memory (GUID-keyed map, one active session), spike cleanup (probe reused for header latency, PIN via Windows notification, secure-storage token, scoped cleartext config).

## Deferred Ideas

- Server tray/settings/revoke UI — Phase 7
- Trackpad sensitivity/acceleration — Phase 4
- TLS/channel binding — out of v1 threat model
