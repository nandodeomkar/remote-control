---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 01
subsystem: api
tags: [protocol, wire-contract, fixtures, bookmarks, chrome-extension, serde, spec]

# Dependency graph
requires:
  - phase: 07-server-shell-settings-tray
    provides: the input.blocked precedent that a NEW fixture family needs a matching test fn in BOTH hard-coded harnesses
  - phase: quick 260716-oi2 / 260716-sme
    provides: the shipped tabs.* family, TabEl/GroupEl element shapes, the ext leg (SPEC section 15) and the 1.4/1.5 minor-bump precedent
provides:
  - protoVersion 1.6 declared in SPEC.md with the full bm.* contract (six registry rows, BmEl element, tri-state TabEl.bookmarked, section-11 pause classification, section-15 ext rows plus caps plus escalated destructive residual)
  - SERVER_PROTO_VERSION = "1.6" with the shared beacon fixture pinned in lockstep
  - Nine golden bookmark fixtures plus the tri-state tabs fixture, byte-identical inputs for both codecs
  - The additive tri-state TabInfo.bookmarked field in BOTH codecs (Rust Option<bool>, Dart bool?)
affects: [11-02, 11-03, 11-04, 11-05, 11-06, 11-07, 11-08, 11-09, 11-10, 11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Tri-state optional wire field: same Option/skip_serializing_if shape as icon/groupId, but None means UNKNOWN rather than there-is-none"
    - "Distinct id field names within one family (nodeId string vs tabId integer) when the id types differ"
    - "Flat breadth-first node list with a virtual root, in place of a recursive tree, to keep the codec non-recursive"

key-files:
  created:
    - protocol/fixtures/bookmarks/01-bm-changed.json
    - protocol/fixtures/bookmarks/02-bm-list-reply-never-connected.json
    - protocol/fixtures/bookmarks/03-bm-open.json
    - protocol/fixtures/bookmarks/04-bm-star.json
    - protocol/fixtures/bookmarks/05-bm-unstar.json
    - protocol/fixtures/bookmarks/06-bm-remove.json
    - protocol/fixtures/bookmarks/07-bm-node-missing-title.json
    - protocol/fixtures/bookmarks/08-bm-open-missing-nodeid.json
    - protocol/fixtures/bookmarks/09-bm-list-request.json
    - protocol/fixtures/tabs/09-tabs-changed-bookmarked.json
  modified:
    - protocol/SPEC.md
    - protocol/fixtures/beacon/01-valid.json
    - server/server-core/src/transport/session.rs
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/tests/integration.rs
    - app/packages/remote_protocol/lib/src/json_codec.dart

key-decisions:
  - "The tabs family is ALREADY registered in both fixture harnesses, so tabs/09-tabs-changed-bookmarked.json went live the moment it hit disk — it was never inert as the plan assumed. TabInfo.bookmarked had to ship in both codecs in this plan to keep master green (Rule 3)"
  - "TabInfo.bookmarked reuses the exact serde/Dart shape of icon and groupId but carries the OPPOSITE meaning for absence: None/null is UNKNOWN, not false — documented in both struct doc comments and SPEC section 7 so no future reader infers not-bookmarked"
  - "The plan's acceptance criteria for grep -c on nodeId/tabId (expected 1) are arithmetically impossible when expect is identical to wire; the fixtures are correct at 2 lines each and the criteria were the error"
  - "The section-15 escalated residual is written as prose asserting a NEW capability class (persistent, non-self-healing destruction) rather than a re-listing of the old one — the bounded blast radius (never removeTree) is the reason it stays accepted, not the loopback bind alone"

patterns-established:
  - "Tri-state optional bool: explicit true/false on every element when the source was readable, key omitted on every element when it was not — never a per-element mix"
  - "Version literal single source of truth (D-09): SERVER_PROTO_VERSION plus the shared beacon fixture move together; the client's version.dart is deliberately NOT bumped because minor mismatch is accepted"

requirements-completed: []

# Metrics
duration: 22min
completed: 2026-07-29
---

# Phase 11 Plan 01: protoVersion 1.6 bm.* wire contract Summary

**protoVersion 1.6 locked in SPEC.md — six `bm.*` messages, the flat BmEl node element with no url and no icon, tri-state `TabEl.bookmarked`, the 500-node/48-char/56 KB-UTF-8-byte ext caps, and an escalated destructive residual — proven by ten new golden fixtures and a version bump pinned to the shared beacon fixture.**

## Performance

- **Duration:** 22 min
- **Started:** 2026-07-29T16:02:00Z
- **Completed:** 2026-07-29T16:24:00Z
- **Tasks:** 3
- **Files modified:** 17 (10 created, 7 modified)

## Accomplishments

- `protocol/SPEC.md` now carries the complete 1.6 contract in one readable place: the header/section-2 version literals and the 1.6 addition bullet, six `bm.*` rows in the section-7 registry, the BmEl element paragraph, the tri-state `bookmarked` paragraph on TabEl, the section-11 pause classification (four commands executor-bound, `bm.list` joined to the read exemption), five section-15 ext-leg rows, the bookmark caps, and the rewritten accepted residual. Any wave-2..7 executor can implement its tier from sections 2/7/11/15 alone.
- `SERVER_PROTO_VERSION` is `"1.6"` with a 1.6 sentence in the in-file changelog block, and both `proto` literals in `protocol/fixtures/beacon/01-valid.json` follow it (the D-09 single-source-of-truth rule). `SERVER_PROTO_MAJOR` stays 1 and the client's `version.dart` was deliberately left at `'1.1'` — a minor mismatch is explicitly accepted by SPEC section 2.
- Ten golden fixtures exist on disk as byte-identical inputs for both codecs: seven positive round trips (including the unknown-key drop, the never-connected install-hint shape, and the bare `{}` request form), two negative hard-decode fixtures, and the D-11 tri-state fixture proving `true` / `false` / absent all round-trip canonically.
- Every bookmark fixture is grep-asserted URL-free and icon-free (T-11-03): the no-url invariant is now enforced by executable contract, not just prose.

## Task Commits

1. **Task 1: Amend SPEC.md with the protoVersion 1.6 bm.* contract** — `19995bf` (docs)
2. **Task 2: Bump SERVER_PROTO_VERSION to 1.6 in lockstep with the beacon fixture** — `b01c5d9` (feat)
3. **Task 3: Create the bookmarks golden-fixture family and the tri-state tabs fixture** — `00d253d` (feat)

## Files Created/Modified

- `protocol/SPEC.md` — the 1.6 contract: version bullet, six registry rows, BmEl, tri-state TabEl.bookmarked, pause classification, ext-leg rows + caps + escalated residual
- `protocol/fixtures/beacon/01-valid.json` — both `proto` literals pinned to `"1.6"`
- `protocol/fixtures/bookmarks/01-bm-changed.json` — folder + link + locked + truncated BmEl round trip, unknown `future` key dropped, snapshot-level `truncated` preserved
- `protocol/fixtures/bookmarks/02-bm-list-reply-never-connected.json` — the `{connected:false, nodes:[]}` install-hint shape
- `protocol/fixtures/bookmarks/03-bm-open.json` — string `nodeId` (and why it is not `id`)
- `protocol/fixtures/bookmarks/04-bm-star.json`, `05-bm-unstar.json` — integer `tabId`, the idempotent non-toggle pair
- `protocol/fixtures/bookmarks/06-bm-remove.json` — string `nodeId`, the D-14 one-node-or-one-empty-folder command
- `protocol/fixtures/bookmarks/07-bm-node-missing-title.json` — NEGATIVE: a BmEl missing a required field is a hard decode error
- `protocol/fixtures/bookmarks/08-bm-open-missing-nodeid.json` — NEGATIVE: `bm.open` with `p:{}`
- `protocol/fixtures/bookmarks/09-bm-list-request.json` — the C→S request form, `p` emitted as `{}`
- `protocol/fixtures/tabs/09-tabs-changed-bookmarked.json` — D-11 tri-state `bookmarked` round trip
- `server/server-core/src/transport/session.rs` — `SERVER_PROTO_VERSION` `"1.5"` → `"1.6"` plus the 1.6 changelog sentence
- `server/server-core/src/executors/mod.rs` — `TabInfo.bookmarked: Option<bool>` (deviation, see below)
- `server/server-core/src/dispatch/router.rs` — `bookmarked: None` at the two `PopulatedTabs` test literals
- `server/server-core/tests/integration.rs` — `bookmarked: None` at the two `sample_tabs` literals
- `app/packages/remote_protocol/lib/src/json_codec.dart` — Dart `TabInfo.bookmarked` (field, `_tabList` parse, ctor, `toJson`, `==`, `hashCode`)

## Decisions Made

- **Fixture `expect` blocks are byte-identical to `wire` for all six positive command/reply fixtures.** The plan's acceptance criteria asked for `grep -c '"nodeId"' 03-bm-open.json` to return 1 and `grep -c '"tabId"' 04-bm-star.json` to return 1, but `grep -c` counts matching LINES and both files carry the key once in `wire` and once in `expect`. The correct value is 2. The plan's own tri-state criterion (`bookmarked` returns 4 — "two in wire, two in expect") confirms both halves are meant to be counted, so this was a criteria miscount and not a fixture defect. Fixtures left correct; criteria treated as satisfied at 2.
- **`bm.*` adds no `err` codes.** The whole family takes the `tabs.activate` fire-and-forget posture; stale ids self-heal via the next `bm.changed` push. This is written into the section-7 rows so no downstream plan invents `bookmarkGone`.
- **The escalated residual names the capability CLASS, not just the message list.** SPEC section 15 now states this is the first ext-leg capability with a persistent, non-self-healing effect (a closed tab is recoverable from history; a deleted bookmark is not, and the phone has no undo), and that the residual stays accepted because the blast radius is bounded by never calling `removeTree` (D-14).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added the tri-state `TabInfo.bookmarked` field to both codecs**

- **Found during:** Task 3 (Create the bookmarks golden-fixture family and the tri-state tabs fixture)
- **Issue:** The plan states the new fixtures are "inert on disk" until 11-03 and 11-07 register the harnesses, and its verification is therefore a structural check. That is true for `protocol/fixtures/bookmarks/` (a NEW family, and neither harness globs directories) but **false for `protocol/fixtures/tabs/09-tabs-changed-bookmarked.json`** — the plan itself notes the tabs family "already enumerates every file", which means the file went LIVE the instant it was written. Both suites turned red: `codec_fixtures_tabs` failed with `encode(decode(wire))` dropping `bookmarked` (no such field on `TabInfo`, so the D-05 unknown-field rule discarded it), and the Dart `tabs fixtures` group failed identically. The plan's own acceptance criteria (`cargo test --workspace` exits 0, `dart test` exits 0) could not be met without the field. Leaving it red would have broken master for every plan up to 11-07.
- **Fix:** Added the additive optional field to both codecs, in exactly the shape 11-02 Task 1 step 5 and 11-07 Task 1 step 3 specify — Rust `#[serde(default, skip_serializing_if = "Option::is_none")] pub bookmarked: Option<bool>`, Dart `final bool? bookmarked;` wired through `_tabList`, the const ctor, `toJson`, `==` and `hashCode`. Both carry a doc comment stating that `None`/`null` means UNKNOWN and not `false`, the one place this shape diverges in meaning from `icon`/`groupId`/`WindowInfo.path`. Four pre-existing `TabInfo` struct literals (two in `router.rs` tests, two in `integration.rs`) got `bookmarked: None`, which keeps the key off the wire and leaves every existing assertion byte-unchanged. **No `bm.*` codec code was written** — the plan's "this plan writes NO codec code" boundary holds for the bookmark family itself.
- **Files modified:** `server/server-core/src/executors/mod.rs`, `server/server-core/src/dispatch/router.rs`, `server/server-core/tests/integration.rs`, `app/packages/remote_protocol/lib/src/json_codec.dart`
- **Verification:** `cargo test --workspace` 186 passed / 0 failed; `dart test` 12 passed; `flutter test` 547 passed
- **Committed in:** `00d253d` (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Necessary for correctness — without it this plan's own three-suite verification fails and master stays red until 11-07. Strictly additive and scoped to the single field the fixture demands; no scope creep into the `bm.*` codec.

**Note for the 11-02 and 11-07 executors:** `TabInfo.bookmarked` ALREADY EXISTS in both codecs. 11-02 Task 1 step 5 and 11-07 Task 1 step 3 are no-ops — verify the field and its doc comment match your plan's wording, then move on. Do not add it twice.

## Issues Encountered

- **`grep -c` line-vs-occurrence semantics** in two of Task 3's acceptance criteria (`nodeId`, `tabId` expected 1, actually 2). Resolved by reasoning from the fixture contract: `expect` must equal `wire` for a positive round trip, so the key necessarily appears on two lines. Fixtures kept correct; documented under Decisions Made.

## User Setup Required

None — no external service configuration required. (The `bookmarks` manifest permission and the extension reload arrow land with 11-04/11-05, not here.)

## Next Phase Readiness

- **Wave 2 is unblocked.** `11-02` (Rust core types: `BmNode`, `BookmarksState`, `trait Bookmarks`, `Executors.bookmarks`) can read SPEC section 7's BmEl paragraph for the exact element shape and `01-bm-changed.json` for the exact serialization.
- `11-03` (Rust codec + router + harness registration) has its nine fixtures on disk and unregistered, exactly as designed — it still owns `codec_fixtures_bookmarks`. Its Task 2 sanity check (corrupt a fixture, confirm RED, revert) remains meaningful.
- `11-07` (Dart codec) likewise has its fixtures waiting; only the `group('bookmarks fixtures')` registration is missing.
- **Carry-forward:** the 56 KB budget loop in `extension/background.js` measures `frame.length` (UTF-16 code units) rather than UTF-8 bytes. SPEC section 15 now mandates the byte measurement for `bm.state`; RESEARCH flags fixing the existing tabs loop the same way as cheap in-scope hardening. That work belongs to the extension plan, not here.

## Self-Check: PASSED

All 11 claimed artifacts exist on disk (SPEC.md, nine bookmark fixtures, the tri-state tabs fixture) and all three task commits (`19995bf`, `b01c5d9`, `00d253d`) are present in git history. Three-suite gate re-run at plan close: `cargo test --workspace` 186 passed, `dart test` 12 passed, `flutter test` 547 passed.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
