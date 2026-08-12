---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 02
subsystem: server
tags: [rust, server-core, executors, transport, ext-relay, bookmarks, watch-channel, socket-tests]

# Dependency graph
requires:
  - phase: 11-01
    provides: protoVersion 1.6 SPEC contract (BmEl element shape, §15 ext rows + 500-node cap, the escalated destructive residual) and the already-shipped TabInfo.bookmarked field
  - phase: quick 260716-oi2 / 260716-sme
    provides: the ext leg itself — run_ext, TabsRelay, ExtCmd, the tabs.state arm, the three session-death reset sites, and the ext_relay.rs socket-test harness
provides:
  - BmNode, BookmarksState, trait Bookmarks and Executors.bookmarks in server-core (zero OS deps, no url and no icon field anywhere)
  - ExtCmd::BmOpen/BmStar/BmUnstar/BmRemove and BookmarksRelay — the Bookmarks executor backed by the ext relay
  - reset_relay_watches — ONE helper resetting BOTH watches at all three session-death sites
  - The strict bm.state ingress arm with the 500-node server belt and the lenient snapshot-level truncated flag
  - Windows composition-root wiring: bm watch channel created, ext_cmd_tx cloned for both relays, run_ext takes both senders
  - Six ext_relay.rs socket tests that ARE the ext-leg bookmark contract (SPEC §15 has no codec harness)
affects: [11-03, 11-04, 11-05, 11-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Multi-watch session cleanup via one extracted helper, so a future watch cannot regress a reset site"
    - "Local serde_json::json! egress envelope on a leg that already parses with a local tolerant frame type — keeps the transport free of the phone-facing codec"
    - "Deferring a struct-field addition to the same commit as its sole production implementor, so no intermediate commit is red"
    - "Mutation-verifying a regression test (delete the fix, confirm exactly that test fails, revert)"

key-files:
  created: []
  modified:
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/executors/mock.rs
    - server/server-core/src/transport/ext.rs
    - server/server-windows/src/main.rs
    - server/server-core/tests/ext_relay.rs

key-decisions:
  - "Executors.bookmarks moved from task 1 to task 2 (Rule 3): adding the field in task 1 would have left server-windows unable to build until task 2 supplied BookmarksRelay, so the field and its only production implementor ship in one commit and every commit stays green"
  - "ExtCmd loses Copy, keeps Clone/Debug/PartialEq/Eq — a String-carrying variant cannot be Copy, and the command arm consumes an owned value straight out of recv() so the move needs no clone"
  - "The four bm frames are built from a local json! envelope rather than the phone-facing codec: run_ext already parses this leg with a local tolerant ExtFrame, so egress stays local too and run_ext takes no dependency on the bm codec landing in 11-03"
  - "bm.state takes the STRICT posture (parse failure keeps the last good tree) while its sibling groups array stays lenient — nodes ARE the payload, and degrading them renders 'you have no bookmarks' as if it were an answer"

patterns-established:
  - "reset_relay_watches is the single session-death cleanup point, documented so a future fourth watch is added there and nowhere else — a missed site becomes structurally impossible rather than merely unlikely"
  - "nodeId (JSON string) vs tabId (JSON number) asserted by TYPE (is_string()/is_i64()), not just by value — a swap decodes fine on both sides and fails silently at the extension, so equality alone would not catch it"

requirements-completed: []

# Metrics
duration: 23min
completed: 2026-07-29
---

# Phase 11 Plan 02: Rust bookmark relay tier Summary

**The server now owns a second extension watch: `bm.state` ingests strictly with a 500-node belt into a `BookmarksState`, the four `bm.*` commands leave with `nodeId` as a JSON string and `tabId` as a JSON number, and both watches reset through one helper at every session-death site — the Pitfall-2 failure is now mutation-proven impossible to reintroduce silently.**

## Performance

- **Duration:** 23 min
- **Started:** 2026-07-29T16:17:00Z
- **Completed:** 2026-07-29T16:40:00Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments

- `server-core` owns the bookmark data model with the no-url invariant enforced by construction: `BmNode` has no `url` field and no `icon` field, so URL resolution can only ever happen extension-side. `BookmarksState::default()` is the never-connected `{connected:false, nodes:[], truncated:false}` shape the phone's install hint keys on.
- `trait Bookmarks` expresses `remove(node_id)` and nothing recursive (D-14). The server tier structurally cannot ask for a subtree wipe, which is the bounded blast radius that keeps SPEC §15's escalated destructive residual accepted.
- **The Pitfall-2 failure is closed and proven closed.** `run_ext` had three independent `tabs_tx.send(TabsState::default())` sites; all three now call `reset_relay_watches`, which resets both watches together. The regression test was mutation-verified: deleting the `bm_tx` line inside the helper fails `ext_disconnect_resets_both_watches` and only that test, then a revert restores 16/16.
- `bm.state` ingest is strict (a malformed `nodes` array keeps the last good tree instead of blanking it), belted at 500 nodes before the watch send regardless of what the extension claims (T-11-07), and preserves the snapshot-level `truncated` flag read leniently.
- The Windows composition root is wired end to end: one ext socket, two watches, one shared command stream. A bind failure still degrades to no-tab-support AND no-bookmark-support rather than killing the server.
- Six new socket tests raise `ext_relay.rs` from 10 to 16. Since SPEC §15 gives the ext leg no codec harness, these tests plus the §15 prose are the entire contract for this tier.

## Task Commits

1. **Task 1: Core bookmark data types, the Bookmarks trait, and the tri-state TabInfo.bookmarked** — `ca3be6a` (feat)
2. **Task 2: Extension relay — bm.state ingress, bm command egress, both-watch reset, main.rs wiring** — `5d8a98d` (feat)
3. **Task 3: ext_relay.rs socket contract tests for the bookmark leg** — `ae261c1` (test)

## Files Created/Modified

- `server/server-core/src/executors/mod.rs` — `BmNode` (flat BmEl: `id`/`parent_id`/`title` wire-required, `folder`/`count`/`locked`/`truncated` optional with the skip-when-absent shape), `BookmarksState`, `trait Bookmarks`, `Executors.bookmarks`
- `server/server-core/src/executors/mock.rs` — `impl Bookmarks for MockExecutors`, four new `Call` variants (`BmOpen`/`BmStar`/`BmUnstar`/`BmRemove`), `bookmarks` added to the recording `Executors` literal
- `server/server-core/src/transport/ext.rs` — `MAX_EXT_BM_NODES = 500`, four `ExtCmd` bookmark variants (`Copy` dropped), `BookmarksRelay` + `impl Bookmarks`, `reset_relay_watches`, the `run_ext`/`handle_ext_text` two-watch signatures, the `"bm.state"` arm, the four `json!` egress envelopes, and a privacy header extended to name bookmark titles (T-11-02)
- `server/server-windows/src/main.rs` — bm watch channel beside the tabs channel, `ext_cmd_tx` cloned so both relays share one command stream, `BookmarksRelay::new(bm_rx, ext_cmd_tx)` in the `Executors` literal, `run_ext(ext_listener, tabs_tx, bm_tx, ext_cmd_rx)`
- `server/server-core/tests/ext_relay.rs` — `Relay.bm_rx`, the `wait_bm_watch`/`bm_state_frame`/`bm_nodes`/`bm_relay` helpers, and six new tests

## Decisions Made

- **`Executors.bookmarks` moved from task 1 to task 2.** The plan put the field in task 1 and its production implementor (`BookmarksRelay`) in task 2. Adding a non-`Option` field to `Executors` immediately breaks `server-windows`' struct literal, so task 1's own gate (`cargo build --workspace` exits 0) could not be met, and committing anyway would leave master unbuildable between two commits. The alternative — a throwaway stub `Bookmarks` impl in `main.rs`, deleted one commit later — is reviewer-hostile noise. Every grep gate in the plan still passes at plan close; only which commit satisfies two of them changed. (`router.rs`'s two `Executors { .., ..base }` literals needed no edit thanks to struct-update syntax.)
- **`grep -c "tabs_tx.send(TabsState::default())"` is 1, not the criterion's 0.** The one remaining occurrence is `ext.rs:184` — the body of `reset_relay_watches` itself, which must perform the send. Zero is arithmetically impossible once the helper exists (short of obfuscating the call). The criterion's intent — no un-migrated inline reset site — is fully satisfied, and criterion 3 (`reset_relay_watches` appears 4 times = 1 definition + 3 call sites) independently confirms all three sites were migrated. Same class as 11-01's documented `grep -c` line-vs-occurrence miscount.
- **The newest-wins replace path deliberately does NOT reset.** The existing non-reset comment applies to bookmarks identically and was extended to say so: a reconnecting extension pushes a full `bm.state` within moments, so blanking the tree on replace would be a visible flicker for no gain.
- **Task 1 step 5 confirmed a genuine no-op.** `TabInfo.bookmarked` already existed from 11-01's Rule-3 deviation. Its doc comment was read against this plan's step-5 wording and already states every required point — `None` means UNKNOWN not `false`, the divergence from `icon`/`group_id`, and the all-or-nothing per-tab emission rule (D-11). No wording delta, no second field added.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Deferred `Executors.bookmarks` from task 1 to task 2**

- **Found during:** Task 1 (Core bookmark data types)
- **Issue:** `Executors` is constructed by a struct literal in `server/server-windows/src/main.rs:171`. Adding `pub bookmarks: Arc<dyn Bookmarks>` in task 1 makes that literal incomplete, so `cargo build --workspace` — task 1's own acceptance gate — fails until task 2 supplies `BookmarksRelay`. Committing task 1 in that state leaves master unbuildable for one commit.
- **Fix:** Task 1 shipped `BmNode`, `BookmarksState`, `trait Bookmarks` and the mock implementation (all workspace-green); task 2 shipped the `Executors.bookmarks` field, the mock literal entry, `BookmarksRelay` and the `main.rs` wiring together. No stub code was written and none had to be deleted.
- **Files modified:** `server/server-core/src/executors/mod.rs`, `server/server-core/src/executors/mock.rs`
- **Verification:** `cargo test --workspace` green at BOTH commits (186 at `ca3be6a`, 186 at `5d8a98d`)
- **Committed in:** `ca3be6a` (task 1) and `5d8a98d` (task 2)

**2. [Rule 3 - Blocking] Updated `spawn_relay` for the new `run_ext` arity inside task 2**

- **Found during:** Task 2 (the `run_ext` signature change)
- **Issue:** The plan assigns the `ext_relay.rs` helper update to task 3 step 1, but changing `run_ext`'s signature in task 2 breaks the only other caller — `spawn_relay` — immediately. Task 2's gate (`cargo test --workspace`) cannot pass with a non-compiling test crate.
- **Fix:** Task 2 made the minimum caller-following change: create the bm channel and pass `bm_tx`, holding the receiver as a local `_bm_rx` so no unused-field warning appears. Task 3 then promoted it to the `Relay.bm_rx` field the tests read, exactly as planned.
- **Files modified:** `server/server-core/tests/ext_relay.rs`
- **Verification:** `cargo test --workspace` green at `5d8a98d` (10 ext_relay tests) and at `ae261c1` (16)
- **Committed in:** `5d8a98d` (task 2) and `ae261c1` (task 3)

**3. [Rule 2 - Missing critical] Extended the `ext.rs` privacy header to name bookmark node titles**

- **Found during:** Task 2 (the `bm.state` arm)
- **Issue:** The module header forbids logging tab titles and urls (T-01-31). A bookmark tree is a durable, higher-value profile of browsing than a live tab list, and the header did not mention it — leaving the T-11-02 mitigation as unwritten convention for whoever adds the first log line to this module.
- **Fix:** Header now names bookmark node titles alongside tab titles/urls and states that any future log line here carries counts and lifecycle only. Zero log lines were added by this plan (server-core stays log-free).
- **Files modified:** `server/server-core/src/transport/ext.rs`
- **Committed in:** `5d8a98d`

---

**Total deviations:** 3 auto-fixed (2 blocking, 1 missing-critical)
**Impact on plan:** Both blocking deviations are commit-ordering only — the plan's full output landed exactly as specified, with every artifact, symbol and grep gate satisfied at plan close. No scope was added or dropped.

## Issues Encountered

- **`grep -c` on the reset-site criterion is unsatisfiable at 0** once the send lives inside a helper. Resolved by reasoning from the criterion's intent (no un-migrated inline site) and cross-checking against the `reset_relay_watches`-count-4 criterion, which proves the migration. Documented under Decisions Made.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-07 (DoS, `bm.state` node flood) | mitigate | `nodes.truncate(MAX_EXT_BM_NODES)` runs before the watch send; `bm_nodes_belt_truncates_at_five_hundred` proves 600 in ⇒ 500 out |
| T-11-02 (info disclosure, ext.rs logging) | mitigate | No log line added; privacy header extended to name bookmark titles |
| T-11-03 (info disclosure, `BmNode`) | mitigate | No `url` and no `icon` field; grep-gated at 0 |
| T-11-04 (tampering, `trait Bookmarks` surface) | mitigate | `remove(node_id)` only — no recursive/subtree method exists to call |
| T-11-10 (tampering, `nodeId`/`tabId` payload) | transfer | Typed `String` vs `i64` variants are the wire-level validation; extension-side `bookmarks.get` validation lands in 11-06 |
| T-11-08 (spoofing, ext listener) | accept | Unchanged — loopback bind plus the existing non-loopback peer drop |
| T-11-SC (supply chain) | mitigate | Zero new crates; no `Cargo.toml` touched |

No new security-relevant surface was introduced beyond the `bm.state` ingress already in the register — no threat flags.

## Known Stubs

None. Everything this plan declares is fully wired. The phone-facing codec/router (`bm.*` messages) and the `bm.changed` push are absent by design — they are 11-03 and 11-04's scope, and the plan stops exactly at the boundary where the tree compiles and the whole existing suite stays green.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **11-03 (Rust codec + router) is unblocked.** `Executors.bookmarks` exists, so the router's `bm.list` read arm and four executor-bound arms have a real executor to call; `BookmarksState`/`BmNode` are the exact types the `bm.list`/`bm.changed` payloads serialize. The nine fixtures from 11-01 are still on disk unregistered, waiting for `codec_fixtures_bookmarks`.
- **11-04 (session push) is unblocked but needs one change here:** `main.rs` currently MOVES `bm_rx` into `BookmarksRelay`. 11-04 must switch that to `bm_rx.clone()` when `ServerDeps` gains its own receiver for the `bm.changed` push branch — the tabs channel at the same site is the exact precedent (`tabs_rx.clone()`).
- **11-05 (extension) has its wire contract pinned.** The four srv→ext frames are now byte-exact and test-locked: `{"t":"bm.open","p":{"nodeId":"<string>"}}`, `bm.star`/`bm.unstar` with `{"tabId":<number>}`, `bm.remove` with `{"nodeId":"<string>"}`. The extension must send `bm.state` with a `nodes` array of BmEl and an optional top-level `truncated` bool.
- **Carry-forward:** unchanged from 11-01 — the `extension/background.js` 56 KB budget loop measures UTF-16 code units, not UTF-8 bytes. SPEC §15 mandates the byte measurement for `bm.state`; that fix belongs to 11-05.

## Self-Check: PASSED

All five claimed files exist on disk and carry the claimed symbols (`pub trait Bookmarks`, `pub struct BmNode`, `rename = "parentId"`, `pub bookmarks: Arc<dyn Bookmarks>`, `impl Bookmarks for MockExecutors`, `MAX_EXT_BM_NODES: usize = 500`, `reset_relay_watches` ×4, `"bm.state"`, `"nodeId"` ×2, `"tabId"` ×2, `BookmarksRelay::new`, `run_ext(ext_listener, tabs_tx, bm_tx, ext_cmd_rx)`). All three task commits (`ca3be6a`, `5d8a98d`, `ae261c1`) are present in git history on `master`. Three-suite gate re-run at plan close: `cargo test --workspace` 192 passed / 0 failed (16 in `ext_relay`), `dart test` 12 passed, `flutter test` 547 passed. Working tree clean.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
