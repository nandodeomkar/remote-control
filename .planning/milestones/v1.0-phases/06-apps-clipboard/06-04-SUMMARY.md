---
phase: 06-apps-clipboard
plan: 04
subsystem: server-windows
tags: [rust, windows, clipboard, arboard, sha2, tokio-watch, dataexchange, privacy]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    plan: 01
    provides: "ServerDeps watch template, authed-gated session push branch, ClipChangedPayload codec, clip.set/clip.get router arms"
  - phase: 06-apps-clipboard
    plan: 02
    provides: "audio_thread OS-thread + pure-predicate template, WinApps sender-only executor shape, main.rs thread-wiring block"
provides:
  - "Core-owned ClipState { text } + ServerDeps.clip watch receiver (zero OS deps, Linux-clean)"
  - "clip.changed authed-gated S->C push branch in session.rs with NO after-auth snapshot (privacy, Pitfall 8)"
  - "clip_thread.rs: run_clip_thread arboard 250ms poll + ClipCmd::Set; pure should_skip_clip / clip_fingerprint / is_echo"
  - "Sensitive-clip skip (ExcludeClipboardContentFromMonitorProcessing presence) + >16 KiB skip + sha2 echo suppression"
  - "WinClipboard executor (watch snapshot reader + mpsc set sender); StubClipboard removed, stubs.rs deleted"
affects: [06-05 Clipboard client send/fetch + history, 06-06 auto-sync + client echo suppression, 06-07 on-device UAT]

# Tech tracking
tech-stack:
  added:
    - "arboard 3.6 (1Password lineage, T-06-SC audited) — PC clipboard text get/set on a dedicated OS thread"
    - "sha2 0.11 in server-windows (RustCrypto, already in server-core) — content-hash fingerprint for echo suppression"
    - "windows feature Win32_System_DataExchange — RegisterClipboardFormatW + IsClipboardFormatAvailable (sensitive-clip presence check)"
  patterns:
    - "Dedicated OS thread owns arboard (no COM — arboard needs no CoInitializeEx, unlike the audio thread)"
    - "Pure privacy-gate predicates (should_skip_clip / clip_fingerprint / is_echo) factored from OS poll for unit test (pct_from_scalar precedent)"
    - "Echo suppression by recorded set-fingerprint: NO push on ClipCmd::Set; the read-back is skipped when its fingerprint matches (D-05)"
    - "Authed-gated watch::changed() push branch with NO after-auth snapshot AND no unconditional snapshot (privacy-strict, distinct from volume)"

key-files:
  created:
    - "server/server-windows/src/clip_thread.rs"
    - "server/server-windows/src/executors/clipboard.rs"
  modified:
    - "server/server-core/src/transport/mod.rs"
    - "server/server-core/src/transport/session.rs"
    - "server/server-core/src/transport/listener.rs"
    - "server/server-core/tests/integration.rs"
    - "server/server-windows/src/main.rs"
    - "server/server-windows/src/executors/mod.rs"
    - "server/server-windows/Cargo.toml"
  deleted:
    - "server/server-windows/src/executors/stubs.rs"

key-decisions:
  - "clip has NO after-auth snapshot AND no unconditional snapshot analog (volume sends one even at default) — the PC clipboard is never dumped implicitly; the client pulls via clip.get (Pitfall 8, T-06-05)"
  - "ClipCmd::Set NEVER pushes to the watch — the value the server wrote is echo-suppressed by fingerprint on the next poll, so get() returns the last EXTERNAL mirrored value (stale-for-self accepted, plan-mandated)"
  - "Sensitive check is fail-open: a 0 exclude_id (RegisterClipboardFormat failure) or a source app that sets no exclusion format is treated as non-sensitive (documented residual risk A3)"
  - "should_skip_clip cap is > 16384 bytes (exactly 16 KiB allowed) using String::len() UTF-8 byte length"

patterns-established:
  - "Clip privacy pipeline: get_text -> sensitive(IsClipboardFormatAvailable) + size gate -> echo fingerprint -> value-equality push_if_changed, every arboard/HRESULT error dropped"
  - "No-unconditional-snapshot contract tested by leaving the watch at default and asserting silence (contrast with volume's drained snapshot)"

requirements-completed: [CLIP-01, CLIP-02, CLIP-03]

# Metrics
duration: ~30min active (spanned a session-limit interruption; 4h wall-clock)
completed: 2026-07-11
---

# Phase 6 Plan 04: Clipboard Send/Fetch + clip.changed Seam Summary

**The no-op `StubClipboard` is replaced by a real arboard-backed `WinClipboard` on a dedicated clipboard thread, plus an authed-gated `clip.changed` push seam: the PC clipboard is now readable/writable over the wire, external PC changes push live to authed phones, and sensitive / >16 KiB / server-echo clips are filtered server-side so secrets never leave the PC — with NO clipboard ever dumped implicitly at auth.**

## Performance

- **Duration:** ~30 min active (the run was cut off by a session limit after all edits but before any commit; resumed and committed cleanly — ~4h wall-clock)
- **Completed:** 2026-07-11
- **Tasks:** 3
- **Files:** 11 touched (2 created, 1 deleted, 8 modified)

## Accomplishments
- **Core clip seam (server-core, Linux-clean):** `ClipState { text }` beside `VolumeState` and `ServerDeps.clip` threaded through `listener` -> `run_session`; an authed-gated `clip.changed` `select!` branch (`== AuthState::Authed`, T-06-05) with a dedicated `clip_changed_frame` helper. DELIBERATELY no after-auth snapshot (unlike volume) — Pitfall 8.
- **Clip thread (`clip_thread.rs`):** owns one `arboard::Clipboard` (Pitfall 6, single-thread) and a 250ms `recv_timeout` poll (audio_thread clone) with NO `CoInitializeEx` (arboard needs no COM). Pure, unit-tested `should_skip_clip` (>16 KiB || sensitive), `clip_fingerprint` (sha2 SHA-256), and `is_echo`.
- **Three server-side privacy gates:** sensitive-clip skip via `RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"))` + `IsClipboardFormatAvailable` presence (Flag 3, fail-open); >16 KiB skip (D-04); echo suppression — the value written from a `clip.set` records its fingerprint and its read-back is never bounced out (Pitfall 5, D-05). A value-equality `push_if_changed` anti-flood guards genuine external changes.
- **WinClipboard executor:** sender-only shape cloned from `WinApps`/`WinMedia` — `get()` reads `snapshot_rx.borrow().text.clone()` (only synchronous touch), `set()` is a send-and-forget `ClipCmd::Set` over mpsc.
- **Composition root + cleanup:** `main.rs` spawns `run_clip_thread`, wires `WinClipboard` into `Executors`, and feeds the real `clip_rx` into `ServerDeps` (Task-1 placeholder gone). `StubClipboard` removed and `stubs.rs` deleted — all five executor traits now have real Windows backends.

## Task Commits

Each task was committed atomically:

1. **Task 1: ClipState + clip.changed authed-gated push seam (server-core)** — `40bec13` (feat)
2. **Task 2: clip thread — arboard poll, sensitive/large gate, echo fingerprint** — `e6e6bf6` (feat)
3. **Task 3: WinClipboard executor + composition-root wiring; remove StubClipboard** — `757ab14` (feat)

## Files Created/Modified
- `server/server-core/src/transport/mod.rs` — `ClipState` struct + `ServerDeps.clip` watch receiver
- `server/server-core/src/transport/session.rs` — `clip_alive` flag, authed-gated `clip.changed` branch (no snapshot), `clip_changed_frame`, `run_session` `clip` param
- `server/server-core/src/transport/listener.rs` — destructure + clone + thread the `clip` receiver into `run_session`
- `server/server-core/tests/integration.rs` — `clip_tx` harness field, `recv_clip_changed`, three clip push tests
- `server/server-windows/src/clip_thread.rs` (new) — `ClipCmd`, pure gate/fingerprint/echo helpers, `run_clip_thread` arboard poll
- `server/server-windows/src/executors/clipboard.rs` (new) — `WinClipboard` executor
- `server/server-windows/src/executors/mod.rs` — `pub mod clipboard;`, dropped `pub mod stubs;`, doc update
- `server/server-windows/src/main.rs` — `mod clip_thread`, clip-thread spawn + channels, `WinClipboard` in `Executors`, real `clip_rx` into `ServerDeps`
- `server/server-windows/Cargo.toml` — `arboard 3.6`, `sha2 0.11`, `Win32_System_DataExchange` feature
- `server/server-windows/src/executors/stubs.rs` (deleted) — `StubClipboard` removed (last stub gone)

## Decisions Made
- **No implicit clipboard exposure.** Volume emits an unconditional after-auth snapshot (drained by `authed_client` even at default); clip emits neither an explicit snapshot block nor any unconditional value at the transition. A freshly-authed phone receives nothing until a genuine external change; it pulls the current value via `clip.get`. This is the concrete, testable form of Pitfall 8 / T-06-05.
- **`ClipCmd::Set` never pushes.** The clip thread writes arboard and records the set fingerprint but does NOT update the watch. On the next poll the read-back matches the fingerprint and is echo-suppressed. Consequence (plan-mandated, accepted): `WinClipboard::get()` returns the last EXTERNAL mirrored value, not the just-set value — harmless because a phone that just set the clipboard already holds that text.
- **Fail-open sensitivity.** If `RegisterClipboardFormatW` returns 0 or a source app sets no exclusion format, the clip is treated as non-sensitive (RESEARCH A3 residual risk) — never a crash, and password managers that DO set the format are still skipped.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Threaded the new `clip` receiver through `listener.rs`**
- **Found during:** Task 1
- **Issue:** `run_session` gained a `clip: watch::Receiver<ClipState>` parameter, but `accept_loop` in `listener.rs` (not listed in the plan's `files_modified`) destructures `ServerDeps` and calls `run_session` — it must clone and pass the new field or the crate does not compile.
- **Fix:** Added `clip` to the `ServerDeps` destructure, a per-connection `clip.clone()`, and the `clip` argument to the `run_session` call — mirroring the existing `volume`/`apps` threading exactly.
- **Files modified:** server/server-core/src/transport/listener.rs
- **Verification:** `cargo test -p server-core` -> 92 lib + 6 fixtures + 19 integration green
- **Committed in:** `40bec13` (Task 1 commit)

**2. [Rule 3 - Blocking] `Cargo.lock` updated by the new dependencies**
- **Found during:** Task 2
- **Issue:** Adding `arboard 3.6` + `sha2 0.11` resolves a new transitive dependency set into `server/Cargo.lock`.
- **Fix:** Committed the regenerated lockfile alongside the manifest (reproducible builds).
- **Files modified:** server/Cargo.lock
- **Verification:** `cargo build --workspace` clean
- **Committed in:** `e6e6bf6` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (both blocking, both mechanical). No scope change — `listener.rs` threading is the same wiring the plan applied to `volume`/`apps`; the lockfile is an automatic consequence of the two planned crates.

## Issues Encountered
- **`clip_no_snapshot_after_auth` test premise corrected during authoring.** The first draft pre-set the clip watch before connecting and asserted silence — but a pre-connection change is a genuine pending watch delta that legitimately fires post-auth (the same positive-control mechanism `apps_no_push_preauth` relies on), so the assertion failed. The real "no snapshot" contract is that clip — unlike volume — has no UNCONDITIONAL snapshot at the transition. Rewrote the test to leave the watch at default (never sent), assert silence at auth, then confirm a real change still pushes. This is a more faithful proof of Pitfall 8 and passes.

## Known Stubs
None — `StubClipboard` was the last interim stub and it is now removed (`stubs.rs` deleted). Every `server_core` executor trait (`MouseKeys`, `Media`, `Power`, `Apps`, `Clipboard`) has a real Windows backend.

## Threat Flags
None — no new security surface beyond the plan's threat register. The `clip.changed` branch carries the `== AuthState::Authed` guard with no implicit snapshot (T-06-05, tested by `clip_no_push_preauth` + `clip_no_snapshot_after_auth`); sensitive clips are skipped by exclusion-format presence (T-06-06, fail-open documented); echo is suppressed by content fingerprint (T-06-07); the 16 KiB cap keeps frames under the 64 KB WS limit (T-06-16); clip text is never logged (T-06-08 — server-core is log-free, the binary logs lifecycle only); the only new crates (arboard, sha2) are the T-06-SC-approved set (no checkpoint required).

## Verification Evidence
- `cargo test -p server-core --test integration clip_` -> 3 passed (`clip_no_push_preauth`, `clip_changed_after_auth`, `clip_no_snapshot_after_auth`).
- `cargo test -p server-core` -> 92 lib + 6 fixtures + 19 integration passed.
- `cargo test -p server-windows` -> 19 passed (incl. `clip_thread::tests::clip_gate`, `clip_thread::tests::clip_echo`).
- `cargo build -p server-windows` and `cargo build --workspace` -> clean, 0 warnings after Task 3.
- Real arboard get/set, live `clip.changed`, and sensitive-clip skip are on-device UAT (06-07) — not CI-testable (needs a real Windows clipboard).

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- The Clipboard server capability is live end-to-end: 06-05 (Clipboard client) can drive `clip.set`/`clip.get` against real arboard and render the pushed `clip.changed` value; 06-06 (auto-sync) can rely on the server-side sensitive/large/echo filtering and gate apply-vs-ignore on the client toggle.
- No blockers. Real-clipboard reliability (sensitive-format coverage of the owner's apps, arboard contention) is the 06-07 on-device gate, as planned.

---
*Phase: 06-apps-clipboard*
*Completed: 2026-07-11*

## Self-Check: PASSED

- Created files verified on disk: server/server-windows/src/clip_thread.rs, server/server-windows/src/executors/clipboard.rs, 06-04-SUMMARY.md
- Deletion verified: server/server-windows/src/executors/stubs.rs removed
- Task commits verified in git log: 40bec13, e6e6bf6, 757ab14
