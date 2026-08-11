---
phase: 02-end-to-end-cursor-spike
verified: 2026-07-08
method: goal-backward (code inspection) + manual-gate assessment
status: gaps_found
gate: BLOCKED — transport spike not exercisable end-to-end
criteria_total: 4
criteria_passed: 0
criteria_blocked: 4
---

> ## SUPERSEDED 2026-08-11 — the gate PASSED; see `02-04-GATE-RESULT.md`
>
> This verification was written on 2026-07-08, **before plan 02-03 built the
> client half it reports as missing** — the client-side pair→challenge→auth
> handshake FSM, the trackpad screen with finger capture, and the latency HUD.
> Every "Missing" and "never called in app code" below was accurate on the day
> it was written and is stale now.
>
> Plan 02-04 then ran the hard transport gate on real WiFi and it **PASSED** at
> **p50 6ms / p95 10ms**, well inside the <30ms PAD-05 budget. That outcome is
> recorded in `02-04-GATE-RESULT.md` and in the ROADMAP's Phase 2 line. This
> verification was simply never re-run afterwards, which is the only reason it
> still reads BLOCKED.
>
> **Read `02-04-GATE-RESULT.md` for the outcome.** The body below is left intact
> as the honest record of what was true on 2026-07-08 — this project marks such
> history rather than deleting it. The frontmatter `status: gaps_found` is also
> **preserved deliberately**, so the file still reads as the artifact it was;
> this banner is the correction, not a rewrite.

# Phase 02 Verification: End-to-End Cursor Spike

**Verdict: GAPS FOUND — the hard transport gate cannot be exercised.**

Phase 02's goal is *"a finger moving on the phone moves the real Windows cursor
with visually instant response over real WiFi."* That end-to-end flow is **not
runnable** with what has been built. The server half is real and runnable; the
client half exists only as unit-tested library functions that **nothing in the
app ever calls**, and the connective tissue (trackpad gesture capture, the
client-side pair→challenge→auth handshake, and the latency HUD) was never built.

## What exists vs. what the goal needs

| Component | Needed for goal | State |
|-----------|-----------------|-------|
| Server cursor injection (enigo input thread, sub-pixel, DPI) | ✅ | **Real & runnable** — `cargo run -p server-windows` prints PIN, listens `0.0.0.0:17777` |
| `connectNoDelay` (TCP_NODELAY WS connect) | ✅ | Defined, unit-tested; **never called in app code** (`lib/net/connection_service.dart:60`) |
| `MoveSender` (delta → encodeMove → sink) | ✅ | Defined, unit-tested; **never called in app code** (`lib/trackpad/move_sender.dart:19`) |
| Trackpad screen / finger capture (`Listener`/`onPointerMove`) | ✅ | **Missing** — `lib/main.dart` is a static `Text('Remote Control — cursor spike')` |
| Client pair→challenge→auth handshake | ✅ | **Missing entirely** — no `hello`/`pin`/`auth` client code exists |
| Server-IP entry / connect trigger | ✅ | **Missing** |
| Latency HUD (measure move-frame RTT) | ✅ (crit 2) | **Missing** |

Verified by grep over `app/remote_control/lib` (excluding tests): the only
references to `MoveSender` and `connectNoDelay` are their own definitions. No
`Listener`, `onPointerMove`, or handshake message strings appear anywhere in
app runtime code.

## Success criteria assessment

1. **Finger moves cursor, no perceptible lag on real WiFi** — ❌ BLOCKED. No
   trackpad screen and no client handshake; the app cannot connect or send.
2. **Move-frame end-to-end latency <30ms, measured on move frames** — ❌ BLOCKED.
   No HUD/instrumentation exists; no frames are ever sent from the app.
3. **No 40–200ms hitches; TCP_NODELAY active both ends** — ⚠️ PARTIAL. Both
   ends set the option in code (server: enigo path; client: `connectNoDelay`
   factory seam), each unit-tested — but "active on the wire" is unproven
   because no live connection is ever made from the app.
4. **Slow diagonal tracks smoothly, sub-pixel + DPI working** — ⚠️ PARTIAL.
   `SubPixelAccumulator` is unit-proven server-side; DPI awareness is set at
   startup — but end-to-end smoothness under real finger input is untestable
   without the client vertical.

## Root cause

The phase was executed as two independent halves (02-01 server, 02-02 client
library seams) and marked complete at 2/2 plans. Both SUMMARYs explicitly defer
the empirical verification to a *"Plan 04 human gate"* and the client trackpad
wiring to *"Plan 02-03"* — **neither 02-03 nor 02-04 was ever planned or
executed**. The connective plan that turns the two halves into a runnable
vertical is missing, so the make-or-break `<30ms` risk the phase exists to
retire remains **unretired**.

## Required to clear the gate

A new plan (the missing 02-03 "wire the vertical") must deliver, at minimum:

- A trackpad screen: `Listener` → `onPointerMove` deltas → `MoveSender`.
- Manual server-IP entry (discovery is Phase 3) + connect via `connectNoDelay`.
- Client-side handshake: `hello` → PIN pair → `challenge` → `auth` (HMAC-SHA256
  of server nonce), reusing `remote_protocol` codecs.
- A latency HUD (echo/timestamp path) to measure move-frame RTT for criterion 2.

Then the manual gate (02-04) can be run on the owner's phone + laptop over real
WiFi against all 4 criteria. WR-01 (pairing PIN one-shot expiry) was fixed
first (commit `54cfcff`) so the manual pairing step will not silently die at 60s.

## Recommendation

Do **not** advance to Phase 03. Phase 02 is a hard gate and is not met. Reopen
the phase: plan and execute the missing end-to-end wiring, then re-run this
verification with the physical devices.
