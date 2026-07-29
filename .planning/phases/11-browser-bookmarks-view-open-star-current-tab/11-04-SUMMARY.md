---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 04
subsystem: server
tags: [rust, server-core, transport, session, push, bookmarks, auth-gate, privacy]

# Dependency graph
requires:
  - phase: 11-02
    provides: BookmarksState + BmNode (core-owned plain data) and the ext relay tier whose run_ext bm_tx is the real producer on this watch
  - phase: 11-03
    provides: Msg::BmChanged + BmChangedPayload — the exact frame the authed-gated push branch encodes
provides:
  - ServerDeps.bookmarks — the watch receiver threaded from run_ext through the accept loop into every session
  - The authed-gated bm.changed select! arm in run_session — the ONLY bookmarks push site, with no after-auth snapshot
  - bm_changed_frame — the sole bm.changed encoder, always emitting truncated, never logging
  - bm_changed_authed_gate_silence_then_single_push — the T-11-01 security test, mutation-proven RED without the auth guard
  - Harness.bm_tx — the test-owned bookmark producer the rest of the phase's server tests can drive
affects: [11-09, 11-10, 11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A new ServerDeps field is ONE compile unit across five files: the struct, the listener destructure, the run_session parameter, the binary's literal, and every test literal — a partial edit does not compile, so they cannot ship apart"
    - "Proving the absence of an after-auth snapshot needs a connection authed BEFORE the watch ever advances; on a connection that saw a pre-auth change, a pending delivery is indistinguishable from a snapshot"

key-files:
  created: []
  modified:
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/src/transport/session.rs
    - server/server-windows/src/main.rs
    - server/server-core/tests/integration.rs

key-decisions:
  - "The no-after-auth-snapshot assertion (T-11-12/D-03) moved onto a SECOND connection inside the same test, because on the pre-auth-silence connection the pending watch delivery is byte-indistinguishable from a snapshot — the plan's step 7 as literally written is unobservable there"
  - "The bm.changed push ALWAYS emits truncated (Some(state.truncated)), matching 11-03's bm.list reply and the 1.5 always-emit-groups posture — a client never has to disambiguate absent-because-old from absent-because-false"
  - "Task 1 lands with one transient dead-code warning (Harness.bm_tx unread until task 2); the field cannot be demoted to a local `_bm_tx` because start_server() moves everything else into the Harness and a local sender would drop at function exit, silently flipping bookmarks_alive false"

patterns-established:
  - "Mutation-verifying a privacy gate: delete the == AuthState::Authed guard, confirm the pre-auth silence assertion is the one that fails, restore and confirm the file is byte-identical to the committed state (git diff --stat empty)"

requirements-completed: []

# Metrics
duration: 14min
completed: 2026-07-29
---

# Phase 11 Plan 04: ServerDeps.bookmarks and the authed-gated bm.changed push Summary

**Bookmark state now reaches authed phones as a live `bm.changed` push cloned byte-for-byte from the shipped `tabs.changed` arm, an unauthenticated peer receives exactly zero bookmark frames no matter how many changes fire — proven by deleting the auth guard and watching the test go RED — and there is deliberately no after-auth snapshot, so a phone that never opens the Bookmarks segment sees no bookmark data at all.**

## Performance

- **Duration:** 14 min
- **Started:** 2026-07-29T18:05:00Z
- **Completed:** 2026-07-29T18:19:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- **`ServerDeps.bookmarks` is wired end to end** — declared in `transport/mod.rs` immediately after `tabs`, destructured and cloned per accepted connection in `listener.rs`, and consumed as `run_session`'s final parameter. The `server-windows` composition root now `clone()`s `bm_rx` into `BookmarksRelay` (snapshot reads for `bm.list`) and moves it into `ServerDeps` (the push), closing 11-02's explicitly recorded carry-forward exactly at the `tabs_rx` precedent.
- **The push arm is authed-gated and is the only bookmarks push site.** `if bookmarks_alive && ctx.auth_state == AuthState::Authed` — the T-11-01 privacy backstop. No `bm.changed` is queued at the auth transition where the D-03 `vol.changed` snapshot is drained, so the apps/clip/tabs posture holds: pull once via `bm.list`, live by push thereafter.
- **The auth guard was mutation-proven load-bearing.** Deleting `&& ctx.auth_state == AuthState::Authed` turned `bm_changed_authed_gate_silence_then_single_push` RED on its FIRST `assert_no_frame`, with the leaked frame printed in full (`{"connected":true,"nodes":[{"id":"11",...}],"truncated":false}`). The guard was restored and `git diff --stat` on `session.rs` is empty against the task-1 commit — byte-identical, not merely equivalent.
- **`bm_changed_frame` carries the full privacy discipline.** No log statement, and a doc comment naming SPEC §12's redaction-mandatory list — node titles never touch a log sink. It always emits `truncated`.
- **`bookmarks_alive` follows the producer-dropped discipline** every other watch branch uses: an `Err(_)` from `.changed()` disables the branch instead of busy-looping forever.
- **The test proves three separate invariants on two connections** — no after-auth snapshot, pre-auth silence across two distinct changes, and exactly one push per post-auth change — plus the disconnect flip (`connected:false`, empty nodes) that makes both browser segments show the install hint together.
- **Wire-shape assertions beyond node count:** `id` is asserted to be a JSON *string* (the T-11-10 nodeId/tabId split, now pinned at the socket level too), a link omits the `folder` key entirely (never `false`, never `null`), and `nodes[0]` is asserted to have **no `url` key** — the SPEC §7 no-url invariant checked on the actual wire rather than trusted from the struct definition.

## Task Commits

1. **Task 1: ServerDeps.bookmarks, listener threading, and the authed-gated bm.changed push arm** — `c2877de` (feat)
2. **Task 2: Integration test — pre-auth silence, then a single post-auth bm.changed push** — `b798fa3` (test)

## Files Created/Modified

- `server/server-core/src/transport/mod.rs` — `BookmarksState` added to the executors import; `pub bookmarks: tokio::sync::watch::Receiver<BookmarksState>` after `pub tabs`, doc-commented in the `tabs` field's voice (push on every change incl. connect/disconnect flips, no after-auth snapshot, `run_ext` is the producer)
- `server/server-core/src/transport/listener.rs` — `bookmarks` in the `ServerDeps` destructure, `let bookmarks = bookmarks.clone();` beside the tabs clone, and the new final argument to `session::run_session`
- `server/server-core/src/transport/session.rs` — `BmChangedPayload` + `BookmarksState` imports, the `mut bookmarks` parameter, the `bookmarks_alive` flag, the authed-gated select! arm after the tabs arm, and `bm_changed_frame` after `tabs_changed_frame`
- `server/server-windows/src/main.rs` — `BookmarksRelay::new(bm_rx.clone(), ext_cmd_tx)`, `bookmarks: bm_rx` in the `ServerDeps` literal, and the step-3d comment rewritten from "MOVES into the relay for now; 11-04 clones it" to the shipped split
- `server/server-core/tests/integration.rs` — `BmNode`/`BookmarksState` imports, a `bookmarks` field on both `ServerDeps` literals, `Harness.bm_tx`, the `recv_bm_changed` helper, `sample_bm_one`/`sample_bm_two`, and the gate test

## Decisions Made

- **The "no after-auth snapshot" assertion lives on a second connection.** The plan's task-2 step 7 asks for an assertion that no `bm.changed` arrives between `authOk` and a deliberate push. On the pre-auth-silence connection that is not observable: the watch advanced while unauthed, so the pending change is delivered as the first post-auth frame and is byte-indistinguishable from a snapshot. The test therefore opens `authed_client(&h)` FIRST — before any `bm_tx.send` — and asserts silence there, which is exactly where a snapshot would have to appear. The pending-delivery frame on the second connection is then used for its real purpose, the positive control that the channel was live and the silence was the auth gate. The plan's own step 7 escape hatch ("if the harness already drains a `vol.changed` after-auth snapshot, keep that drain") is honoured — `authed_client` drains it.
- **`truncated` is always emitted on the push**, matching 11-03's identical choice for the `bm.list` reply. `BookmarksState.truncated` is a plain `bool`, so `Some(state.truncated)` is unconditional; a 1.5-or-older client drops the unknown key per SPEC §1.
- **`Harness.bm_tx` stays a struct field despite the one-commit dead-code warning.** The obvious fix — a local `_bm_tx` binding in `start_server()` — is wrong: every other sender is *moved into* the Harness, so a local would drop at function exit and flip `bookmarks_alive` false on every session, silently disabling the branch under test and making the whole suite pass for the wrong reason. The field is documented in-file with that rationale so no future author "simplifies" it back.
- **The disconnect-flip assertion was added to the gate test** rather than split into a `tabs_changed_after_auth_then_disconnect_hint` analog. The plan's must-have truth names the connect/disconnect flip explicitly, and it costs three lines on an already-authed connection at the end of the same test.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `Harness.bm_tx` dead-code warning during task 1**

- **Found during:** Task 1 verification
- **Issue:** The plan instructs task 1 to expose the bookmarks sender on the test Harness so task 2 can drive pushes. Nothing reads it until task 2, so `cargo test --workspace` emitted `warning: field bm_tx is never read` at the task-1 commit point — a break in the repo's zero-warning invariant.
- **Fix attempted and rejected:** demoting the field to a local `_bm_tx` binding in `start_server()`. That compiles warning-free but is a real bug: the sender would drop at function exit, `bookmarks_alive` would flip false on every session, and the entire bookmarks branch would be silently disabled. Caught before committing.
- **Fix applied:** kept the field as the plan specifies and accepted the single transient warning, which task 2 resolves in the very next commit. `cargo build --workspace` (the stated no-warnings gate) never sees it — `build` does not compile test targets. The in-file doc comment now states why the field must be Harness-owned.
- **Files modified:** `server/server-core/tests/integration.rs`
- **Commits:** `c2877de` (transient), `b798fa3` (resolved)

No Rule 1, 2 or 4 deviations. No architectural questions arose.

## Issues Encountered

The gate test passed on its first run, which is precisely why the plan mandated the guard-removal experiment — a first-run green is also what a test with a broken assertion produces. The mutation confirmed the test fails for the right reason, on the right assertion, with the leaked frame visible in the panic message.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-01 (info disclosure, `bm.changed` select! arm) | mitigate | The arm carries `if bookmarks_alive && ctx.auth_state == AuthState::Authed`. `bm_changed_authed_gate_silence_then_single_push` asserts zero frames across two distinct pre-auth changes and was **verified RED** with the guard deleted — the failure landed on the first `assert_no_frame`, not incidentally elsewhere. Guard restored byte-identical |
| T-11-02 (info disclosure, `bm_changed_frame`) | mitigate | Zero log statements in the encoder or the arm; the doc comment names the SPEC §12 redaction-mandatory discipline it inherits from `tabs_changed_frame`. No node title is constructed into any string outside the JSON encode |
| T-11-12 (info disclosure, after-auth snapshot) | mitigate | No `bm.changed` is queued at the auth transition. Asserted on a connection authed BEFORE the watch ever advanced — the only place the absence is observable — so a freshly authed phone that never opens the Bookmarks segment receives no bookmark data at all |
| T-11-07 (DoS, push channel backpressure) | mitigate | `tx.try_send` with the tabs arm's exact three-way handling: `Full` drops the frame (the latest-value watch self-heals on the next change), `Closed` breaks onto the CONN-07 cleanup. The read loop never blocks on the write queue |
| T-11-SC (tampering, supply chain) | mitigate | Zero new crates; no `Cargo.toml` touched in either workspace member |

**Threat surface scan:** no new network endpoints, auth paths, file access, or trust-boundary schema beyond the `bm.changed` push already in the register. No threat flags.

## Known Stubs

None. Every symbol this plan declares is implemented and exercised. The `bm.changed` producer side (`run_ext`'s `bm_tx`) already shipped in 11-02; this plan connects its consumer end, so the relay leg is complete server-side.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **The server half of the bookmarks relay is complete.** A phone that authenticates, sends `bm.list` once (pause-exempt, 11-03) and then listens receives a live `bm.changed` on every bookmark change and on the extension connect/disconnect flip. 11-09+ (the widget layer) and 11-11/11-12 can build against a real, running contract rather than a stub.
- **`Harness.bm_tx` is available to any later server test** that needs to drive a bookmark change, exactly as `tabs_tx` served the tabs suite.
- **Suite baseline for the next wave:** `cargo test --workspace` 202 passed / 0 failed (integration 24 → 25), `cargo build --workspace` clean with zero warnings.
- **Carry-forward (unchanged, still open):** `extension/background.js`'s 56 KB budget loop measures UTF-16 code units, not UTF-8 bytes, while SPEC §15 mandates the byte measurement for `bm.state`. That belongs to the extension plan and is untouched here.

## Self-Check: PASSED

All five claimed files exist on disk and carry the claimed symbols: `pub bookmarks: tokio::sync::watch::Receiver<BookmarksState>` x1 in `mod.rs`; `bookmarks` x3 in `listener.rs` (destructure, clone, call argument); `ctx.auth_state == AuthState::Authed` count 9 → 10 in `session.rs`, exactly one more than the pre-plan baseline (`git show HEAD:...` confirmed 9); `fn bm_changed_frame` x1; `bookmarks_alive` x3; `bookmarks: bm_rx` x1 in `main.rs`; `bookmarks:` x2 in `integration.rs`; `fn bm_changed_authed_gate_silence_then_single_push` x1; `bm.changed` x12 lines in `integration.rs` (criterion: 2+).

Both task commits are present in git history on `master`: `c2877de` (feat) and `b798fa3` (test).

Gate at plan close: `cargo build --workspace` exits 0 with **zero warnings**; `cargo test --workspace` 202 passed / 0 failed / 2 ignored (the two pre-existing live-Windows-COM ignores); `cargo test -p server-core --test integration bm_changed_authed_gate` reports exactly 1 test passed. Guard-removal experiment performed and reverted — `git diff` on `session.rs` against `c2877de` is empty. No Dart or Flutter source was touched by this plan.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
