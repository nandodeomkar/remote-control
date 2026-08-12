# Milestones

## v1.0 MVP — shipped 2026-08-12

**12 phases · 108 plans · 244 tasks · 673 commits · 2026-07-07 → 2026-08-12 (37 days)**

Released as `v1.6.3` on the public mirror (`nandodeomkar/remote-control-releases`):
APK, Inno Setup PC installer, and browser extension, each with a published SHA-256.

**Delivered:** an Android app that turns the phone into a wireless mouse, keyboard
and control centre for a Windows laptop, paired with a Rust tray server — every
feature free, on a dark-minimal UI. It replaced the paid app it was written against.

### Key accomplishments

1. **A versioned wire contract proven in two languages.** `SPEC.md` (protoVersion
   1.0 → 1.8) with challenge-response auth, grapheme-counted diff-ops text and
   9-byte binary mouse frames, pinned by golden fixtures that the Rust and Dart
   codecs decode identically — including a .NET-computed auth proof as a
   cross-language anchor.

2. **The cursor budget retired early, on hardware.** The phase-2 spike measured
   **p50 6ms / p95 10ms** round-trip-under-load over real WiFi — ~3× under the
   30ms budget — which locked WebSocket-only transport and meant no later phase
   had to relitigate it.

3. **Connectivity became a solved problem for every screen after phase 3.** UDP
   beacon discovery, PIN pairing with lockout, SHA-256-only token storage, silent
   reconnect, and a pure IO-free reconnect FSM — demonstrated end to end on the
   owner's Xiaomi + Windows 11 pair.

4. **The product-defining surfaces: trackpad and keyboard.** Absolute SendInput
   cursor injection that bypasses the Windows pointer-ballistics curve, a pure
   gesture-classifier FSM, IME-correct typing, and a stuck-key model with a
   liveness deadline so a half-open TCP connection can no longer leave a modifier
   physically held on the PC.

5. **Control-centre breadth:** media with absolute WASAPI volume, double-confirmed
   power actions behind a deliberate-gesture contract, presenter, browser macros,
   live window/app management, bidirectional clipboard with loop-safe auto-sync,
   and browser tab + bookmark control through a Chrome extension relay.

6. **It updates itself.** Phone, PC server and extension each report installed vs.
   latest and install with one tap; `tools/release.ps1` bumps all three versions,
   builds all three artifacts and publishes them to a public mirror so no auth
   token ships in any build. **Observed on hardware 2026-08-08:** `1.6.2` → `1.6.3`
   in three seconds spawn-to-back-up, extension self-reloaded, phone reconnected
   on its own.

### Closeout

**Type: `override_closeout`.** Every phase goal is met and all 38 v1 requirements
are traced Complete, but 5 of 12 phases do not carry a passing `VERIFICATION.md`:

- **Phase 02** — `gaps_found`, left that way on purpose. Stale, not failing: never
  re-run after 02-03 built the client half it complained was missing, and
  superseded by `02-04-GATE-RESULT.md` (hard gate PASS).
- **Phases 06, 08, 09, 12** — no `VERIFICATION.md` written. Outcome evidence exists
  for each (UAT records, UAT-gated summaries, and the 2026-08-08 on-hardware
  observation for 12). Documentation debt, not unproven work.

**10 items acknowledged as deferred** — see `.planning/STATE.md` `## Deferred Items`.
None is a blocker. The pre-close audit initially reported 19 open items; 15 were
stale or missing frontmatter, corrected in `b28f32a` before the close.

### The lesson this milestone paid for

For eight weeks the progress counter read **100%** while `12-18-SUMMARY.md` carried
`## Self-Check: FAILED`. The PC self-update shipped broken in `1.6.0` and `1.6.1` —
a `DETACHED_PROCESS | CREATE_NO_WINDOW` flag pair that is invalid, and a helper
that blocked forever on `tasklist | find`. No test caught it because `spawn_helper`
sat behind the one seam the test suite injects around.

**A SUMMARY on disk is not an outcome.** The converse held too: phase 02's
pessimistic `gaps_found` artifact was not a failure. Both directions cost real time
to discover.

### Archived

- `.planning/milestones/v1.0-ROADMAP.md`
- `.planning/milestones/v1.0-REQUIREMENTS.md`
- `.planning/milestones/v1.0-MILESTONE-AUDIT.md`
- `.planning/milestones/v1.0-phases/` (all 12 phase directories)

---
