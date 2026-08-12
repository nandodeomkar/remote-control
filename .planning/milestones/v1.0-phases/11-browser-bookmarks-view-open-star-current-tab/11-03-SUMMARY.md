---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 03
subsystem: server
tags: [rust, server-core, codec, router, fixtures, bookmarks, pause-gate, wire-contract]

# Dependency graph
requires:
  - phase: 11-01
    provides: the protoVersion 1.6 SPEC contract (six bm.* registry rows, the BmEl element, the section-11 pause classification) and the nine golden bookmark fixtures
  - phase: 11-02
    provides: BmNode, BookmarksState, trait Bookmarks and Executors.bookmarks — the executor the router arms call into
provides:
  - The six bm.* payload structs (BmListPayload, BmChangedPayload, BmOpenPayload, BmStarPayload, BmUnstarPayload, BmRemovePayload) with the typed nodeId/tabId split
  - Msg::BmList/BmChanged/BmOpen/BmStar/BmUnstar/BmRemove plus six decode and six encode arms — the phone-facing codec now speaks the whole family
  - Router classification — bm.list as a pause-exempt READ, four executor-bound fire-and-forget commands, bm.changed in the S-to-C-only silent-ignore group, zero new err codes
  - codec_fixtures_bookmarks — the Rust half of the cross-language parity proof, hard-registered and corrupt-verified
  - Four router unit tests pinning the whole section-11 classification plus the nodeId/tabId pass-through
affects: [11-04, 11-06, 11-08, 11-09, 11-10, 11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Codec + router as ONE commit unit when Msg gains a variant: the exhaustive catch-all-free match makes a variant without an arm a compile error, so the two files cannot ship apart"
    - "Mutation-verifying a pause-gate test (delete the is_executor_bound entry, confirm exactly that test fails, restore)"

key-files:
  created: []
  modified:
    - server/server-core/src/codec/json.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/tests/fixtures.rs

key-decisions:
  - "The is_executor_bound bm entry is written as ONE line of four alternatives rather than the surrounding one-per-line style, because the plan's acceptance criterion greps for that exact literal — a formatting concession to an executable gate, with no semantic effect"
  - "The bm.list read arm ALWAYS emits truncated (Some(state.truncated)), mirroring the 1.5 'server always emits groups' posture — a 1.5-or-older client drops the unknown key per D-05, and a client that reads it never has to distinguish absent-because-old from absent-because-false"
  - "The wrong-direction test asserts BOTH the empty-reply invariant AND the absence of any Msg::Err, so a future author who 'helpfully' adds an err for bm.changed fails on the specific assertion rather than on an opaque length check"
  - "Zero grep-criterion discrepancies this plan — unlike 11-01 and 11-02, every count criterion was arithmetically satisfiable and satisfied exactly as written"

patterns-established:
  - "A fixture family's registration is only real if proven: corrupt one expect block, confirm RED, revert, and record that the check ran (now done for the Rust harness as 11-07 did for Dart)"

requirements-completed: []

# Metrics
duration: 7min
completed: 2026-07-29
---

# Phase 11 Plan 03: Rust bm.* codec, router and fixture registration Summary

**The phone-facing Rust codec now speaks all six `bm.*` messages with `nodeId` typed `String` and `tabId` typed `i64` so a swap is a hard decode error, the router answers `bm.list` while paused and drops all four commands, and `codec_fixtures_bookmarks` drives the same nine golden files the Dart harness already claims — cross-language parity is now proven, not merely intended.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-07-29T17:20:00Z
- **Completed:** 2026-07-29T17:27:00Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- The codec's six payload structs mirror the Dart classes 11-07 shipped field for field. `BmListPayload` is all-optional so the bare `{}` request decodes; `BmChangedPayload` is the strict sibling where a missing `connected` or `nodes` is a hard `MissingField` error, exactly as fixture 07 demands.
- **The `nodeId`/`tabId` type split is now enforced in the Rust codec too (T-11-10).** `BmOpenPayload`/`BmRemovePayload` carry `String`, `BmStarPayload`/`BmUnstarPayload` carry `i64`; a swap cannot decode. The doc comment on `BmOpenPayload` states WHY the two id kinds are named apart — reusing one key `id` would decode fine under the value-lenient codec and then fail silently inside the extension.
- The router's SPEC section 11 classification is complete and test-pinned: `bm.list` joins `apps.list`/`clip.get`/`tabs.list` in the read exemption, all four commands are `is_executor_bound` (so pause drops them, D-13/D-14 destructive actions included), and an inbound `bm.changed` is ignored with no `err{unknownType}` — the type IS known, only the direction is wrong.
- **Zero new err codes.** The family keeps its fire-and-forget posture (SPEC section 7); stale ids self-heal via the next `bm.changed` push. Grep-gated at 0 for `bookmarkGone|bmError|bookmarkFailed`.
- **The fixture registration was proven real, not assumed.** Corrupting `03-bm-open.json`'s `expect.nodeId` to `"CORRUPT"` turned `codec_fixtures_bookmarks` RED with the exact left/right diff; the revert restored green and `git diff --name-only protocol/fixtures/` is empty. The nine golden files were byte-untouched at plan close.
- **The paused-drop test was mutation-verified.** Deleting the `Msg::BmOpen(_) | Msg::BmStar(_) | Msg::BmUnstar(_) | Msg::BmRemove(_)` line from `is_executor_bound` failed `paused_drops_every_executor_bound_family_silently` and nothing else; restoring it returned 34/34 router tests. The pause gate is proven load-bearing rather than incidentally green.

## Task Commits

1. **Task 1: bm.* payload structs, Msg variants and router arms (one compile unit)** — `b24475f` (feat)
2. **Task 2: Register the bookmarks fixture family with the Rust harness** — `e4f8401` (test)
3. **Task 3: Router pause, read-exemption and wrong-direction unit tests** — `d046b5f` (test)

## Files Created/Modified

- `server/server-core/src/codec/json.rs` — `BmNode` added to the executors import; the six `Bm*Payload` structs between `TabsClosePayload` and `BrowserPayload`; six `Msg` variants after `TabsClose`; six decode arms and six encode arms in family order
- `server/server-core/src/dispatch/router.rs` — `BmListPayload` import, the `bm.list` READ arm, four fire-and-forget executor arms, four `is_executor_bound` entries plus its extended doc comment, `Msg::BmChanged(_)` in the S-to-C-only group, the pause-gate comment extended to name `bm.list`, and in the test module: `PopulatedBookmarks`, the four extended/new tests
- `server/server-core/tests/fixtures.rs` — `codec_fixtures_bookmarks()` after `codec_fixtures_tabs`, with the 07-02 no-globbing rationale in its doc comment

## Decisions Made

- **`truncated` is always emitted on the `bm.list` reply.** `BookmarksState.truncated` is a plain `bool`, so the arm sends `Some(state.truncated)` unconditionally — the same posture as the 1.5 `groups` array. A 1.5-or-older client drops the unknown key (D-05) and a 1.6 client never has to disambiguate "absent because the server is old" from "absent because false". Fixture `02-bm-list-reply-never-connected.json` is unaffected: it exercises the DECODE direction of a reply built elsewhere, where an absent `truncated` stays `None` and re-encodes absent.
- **The `is_executor_bound` bm entry is one line, not four.** The surrounding list puts one variant per line, but the plan's acceptance criterion greps for the exact literal `Msg::BmOpen(_) | Msg::BmStar(_) | Msg::BmUnstar(_) | Msg::BmRemove(_)`. The one-line form satisfies the executable gate and has no semantic effect. No rustfmt config or pre-commit hook exists in this repo, so nothing will silently reflow it.
- **The wrong-direction test asserts the absence of `Msg::Err` explicitly**, on top of the empty-reply assertion, and names the direction rule in its failure message. A bare `is_empty()` would pass for the wrong reason if someone later routed `bm.changed` somewhere that happened to return nothing; the explicit `!any(Msg::Err)` assertion states the actual invariant.
- **No grep-criterion discrepancy this plan.** Both prior waves documented `grep -c` line-vs-occurrence miscounts, and the upstream note warned to expect another. Every criterion here was checkable as written and passed exactly: 6 structs, 12 `"bm.` lines, 2 `nodeId` renames, 2 `tabId` renames, 5 `exec.bookmarks.` calls, 3 non-comment `BmNode` mentions (criterion: 2+), 4 `PopulatedBookmarks` lines (criterion: 2+), 7 `bm.open|BmOpen` lines (criterion: 4+), 0 new err codes.

## Deviations from Plan

None — plan executed exactly as written. All three tasks landed in their planned files with their planned symbols, and no deviation rule (1-4) was triggered.

## Issues Encountered

None. The fixture family passed green on its very first run, which is why the mandated corrupt-then-revert experiment mattered: a first-run green is exactly the signal that an UNREGISTERED family also produces.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-09 (EoP, `bm.*` routing) | mitigate | `route` is structurally unreachable before `AuthState::Authed` (gate 1, unchanged); the four commands are in `is_executor_bound` so gate 2 drops them while paused — mutation-proven by deleting the entry and watching exactly `paused_drops_every_executor_bound_family_silently` fail |
| T-11-10 (tampering, `nodeId`/`tabId` type confusion) | mitigate | Distinct wire key names with distinct Rust types (`String` vs `i64`); fixtures 03-06 round-trip both, fixture 08 pins the missing-field case, and `bm_commands_route_when_unpaused` asserts each id reaches its own `Call` variant unswapped |
| T-11-05 (tampering, `bm.remove` on a managed node) | transfer | The router passes the opaque `node_id` straight through with no interpretation — unchanged; Chrome's rejection and the phone's `locked` affordance are the other two lines |
| T-11-02 (info disclosure, router err strings) | mitigate | Zero new err codes and zero new err strings added; grep-gated at 0. No log line anywhere in this plan |
| T-11-06 (tampering, `bm.unstar` blast radius) | transfer | Unchanged — the server never sees a URL; matching and the delete loop live in the extension (11-06) |
| T-11-SC (supply chain) | mitigate | Zero new crates; no `Cargo.toml` touched |

No new security-relevant surface beyond the `bm.*` routing already in the register — no threat flags.

## Known Stubs

None. Every symbol this plan declares is fully implemented and exercised by either a golden fixture or a router unit test. The `bm.changed` server PUSH is absent by design — 11-04 owns the session branch, and this plan stops at the point where a client-sent `bm.changed` is correctly ignored.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **11-04 (session push) is unblocked on the codec.** `Msg::BmChanged(BmChangedPayload { connected, nodes, truncated })` exists with `connected`/`nodes` required, which is exactly the frame the authed-gated push branch must build. 11-02's carry-forward still stands: `main.rs` currently MOVES `bm_rx` into `BookmarksRelay` and must switch to `bm_rx.clone()` when `ServerDeps` gains its own receiver (the `tabs_rx.clone()` site is the precedent).
- **11-08+ (the app tier) has a live server contract.** A phone sending `BmListMsg()` now gets a real `bm.list` reply carrying `connected`, `nodes` and `truncated` — including while paused, which is the D-03 behaviour the Bookmarks segment's first display depends on.
- **Cross-language parity is now complete for the family.** Both harnesses name `bookmarks` and drive the identical nine files; a future codec change that diverges the two languages fails in one of them.
- **Carry-forward:** unchanged from 11-01/11-02 — `extension/background.js`'s 56 KB budget loop measures UTF-16 code units, not UTF-8 bytes, and SPEC section 15 mandates the byte measurement for `bm.state`. That fix belongs to the extension plan.

## Self-Check: PASSED

All three claimed files exist on disk and carry the claimed symbols: `pub struct Bm*Payload` x6, `"bm.` x12 in `json.rs` (six decode + six encode arms), `rename = "nodeId"` x2, `rename = "tabId"` x2, `exec.bookmarks.` x5 in `router.rs`, the one-line `is_executor_bound` bm entry at :364, `Msg::BmChanged(_)` in the S-to-C-only group at :336, `PopulatedBookmarks` x4, `fn codec_fixtures_bookmarks` x1 and `run_json_family("bookmarks")` x1. All three task commits (`b24475f`, `e4f8401`, `d046b5f`) are present in git history on `master`.

Three-suite gate at plan close: `cargo test --workspace` 197 passed / 0 failed (baseline 192, +1 fixture family, +4 router tests), `dart test` 13 passed, `flutter test` 547 passed. `cargo build --workspace` exits 0 with no warnings. `git diff --name-only protocol/fixtures/` empty — no fixture was edited to fit the codec. Working tree clean.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
