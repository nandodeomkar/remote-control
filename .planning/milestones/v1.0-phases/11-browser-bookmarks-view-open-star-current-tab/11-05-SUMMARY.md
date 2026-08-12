---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 05
subsystem: extension
tags: [chrome-extension, mv3, service-worker, bookmarks, bm-state, frame-budget, utf8, bfs, privacy]

# Dependency graph
requires:
  - phase: 11-01
    provides: protoVersion 1.6 SPEC §7 BmEl element shape and the §15 ext caps (500 nodes / 48-char titles / 56 KB measured in UTF-8 BYTES)
  - phase: 11-02
    provides: the server side that consumes bm.state — strict ingress with a 500-node belt, the four bm.* command frames, and reset_relay_watches
  - phase: quick 260716-oi2 / 260716-sme
    provides: the Tab Bridge extension itself — connect/backoff, the 200 ms debounce, buildAndSend, the icon-strip budget loop and the counts-only send log
provides:
  - The `bookmarks` manifest permission (read + write, the whole phase's ext-side capability)
  - MAX_BM_NODES 500 / MAX_BM_TITLE 48 and `bytesOf` — UTF-8 byte measurement for EVERY frame budget, including the previously buggy shipped tabs loop
  - Top-level chrome.bookmarks listeners behind an optional-API guard, with the onImportBegan/onImportEnded storm guard
  - buildAndSendAll — the single debounce target: one settling gap, one getTree() walk, two frames
  - buildBmSnapshot — BFS from the root's children, capped, byte-budgeted, truncation-flagged, url-free and icon-free
  - The module-level bmUrlSet carrying the D-11 tri-state star truth (11-06 consumes it)
affects: [11-06, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Frame budgets measured with TextEncoder byte length, never String.prototype.length — a code-unit count under-measures non-ASCII by up to 3x"
    - "Truncation flags applied INSIDE the serialize step so the bytes measured are the bytes sent (the flags themselves cost bytes)"
    - "Unreadable source degrades to NO frame, never to an empty frame — an empty snapshot is a lie the phone cannot distinguish from the truth"
    - "Title caps trim a trailing lone surrogate, because a split emoji is a hard decode error on a strictly-parsed wire"

key-files:
  created: []
  modified:
    - extension/manifest.json
    - extension/background.js

key-decisions:
  - "The bm.state send + counts-only log block lives in buildAndSendAll (task 2's stated scope) rather than inside buildBmSnapshot (task 3 step 7's wording); buildBmSnapshot stays a pure builder returning {frame, urls, count} or null. This also keeps every intermediate commit runtime-safe — at task 2's commit the not-yet-existing builder throws, the caller's catch degrades to tabs-only, and the shipped tab path never breaks"
  - "capBmTitle trims a trailing lone high surrogate after the 48-char slice (Rule 2): JSON.stringify of a split emoji emits a bare \\ud83d, serde_json rejects it as a hard decode error, and bm.state ingest is STRICT — so ONE emoji-decorated title landing on the cap boundary would silently cost the phone its entire bookmark tree"
  - "Truncation flags are applied before the byte measurement, not after it: `truncated:true` costs ~18 B per flagged node plus the payload key, enough to push a frame that just fit back over the 56 KB line. The serialize step is a closure the drop loop re-runs, so the loop converges on the frame that actually ships"
  - "A capped-out node records its parentId in `dropped` but does NOT enqueue its children — the cap prunes whole subtrees at the frontier, which is what keeps the BFS guarantee (all roots and their top levels first) meaningful"

patterns-established:
  - "bytesOf is the ONE frame-measurement helper in the file; `frame.length` now appears zero times and any future budget loop inherits the byte measurement by using it"
  - "Optional-API guard shape (`if (chrome.bookmarks) { … }`) cloned from the shipped `if (chrome.tabGroups)` block, so a withheld permission or a non-Chromium fork still loads the worker and still reports tabs"

requirements-completed: []

# Metrics
duration: 7min
completed: 2026-07-29
---

# Phase 11 Plan 05: Extension bookmark snapshot leg Summary

**The Tab Bridge now reads the bookmark tree and pushes it as one breadth-first `bm.state` snapshot on the same 200 ms debounce as the tab list — and every frame budget in the file, including the shipped tabs loop that has been latently wrong since 260716-oi2, is now measured in UTF-8 bytes instead of UTF-16 code units.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-07-29T16:39:04Z
- **Completed:** 2026-07-29T16:46:13Z
- **Tasks:** 3
- **Files modified:** 2

## Accomplishments

- **Pitfall 1 is closed on both paths.** `bytesOf(s)` (TextEncoder) replaced `frame.length` in the shipped tabs loop and is the measurement in the new bookmark loop. `grep -c "frame.length"` is now 0. A local harness proved the consequence concretely: 900 bookmarks with 60-char CJK + emoji titles serialize to a frame that the OLD measurement would have read as ~19 000 "bytes" and shipped at ~170 KB — past the server's 64 KB `max_message_size`, which kills the ext session and silently flips the phone to the install hint. The new loop drops it to 311 nodes / **57 172 bytes**, inside the 57 344 budget.
- **`buildBmSnapshot` walks breadth-first and the walk order is load-bearing, not stylistic.** Seeded from `tree[0].children`, so root `"0"` is never emitted (Pitfall 5) and every root plus every root's top level lands before any depth-2 node — the structural guarantee behind D-08's "nothing in the collection is unreachable." Harness-verified: a tree with three roots and a depth-3 leaf emits `1,2,3,4,5,6`.
- **One debounce, one `getTree()` walk, two frames.** `buildAndSendAll` is now the single `setTimeout` target AND the on-open push inside `connect()`; it builds the bookmark snapshot first (rebuilding `bmUrlSet`) and then awaits the existing `buildAndSend()`, so the tab snapshot 11-06 will decorate with `bookmarked` always reads a fresh URL set.
- **An unreadable tree sends nothing at all.** `chrome.bookmarks` absent, `getTree()` throwing, or any unexpected throw ⇒ `null` ⇒ `bmUrlSet = null` and no `bm.state` frame. The server's `BookmarksState` stays `connected:false` and the phone shows the honest shared install hint, instead of being told "you have no bookmarks."
- **The import storm is coalesced away** (Pitfall 3) with Chrome's own documented mitigation: `bmImporting` set by `onImportBegan`, cleared by `onImportEnded`, which then schedules exactly one snapshot for the entire import.
- **T-11-03 holds by construction.** The element carries `id`, `parentId`, `title` plus `folder`/`count`/`locked`/`truncated` and nothing else; `n.url` reaches only a module-local `Set`. Gated by the automated `url leaked into a bm element` assertion and confirmed on a real serialized frame (`"url"` and `"icon"` both absent).

## Task Commits

1. **Task 1: bookmarks permission, bookmark caps, byte-accurate frame measurement** — `84d6f54` (feat)
2. **Task 2: Top-level bookmark listeners with the import-storm guard on the shared debounce** — `931fc4c` (feat)
3. **Task 3: buildBmSnapshot — BFS walk, caps, byte-measured drop loop, truncation flags** — `1634fdb` (feat)

## Files Created/Modified

- `extension/manifest.json` — `permissions` gains `"bookmarks"`. Exactly one changed line; `version` deliberately untouched (11-12 owns the release-facing wording once UAT-1 has recorded what Chrome does on reload).
- `extension/background.js` —
  - header extended to name bookmark snapshots, the `bm.*` commands, and bookmark titles/urls in the never-log rule (T-11-02)
  - `MAX_BM_NODES = 500`, `MAX_BM_TITLE = 48` with the SPEC §15 sync comment
  - `bytesOf(s)` plus the comment explaining the code-unit-vs-byte failure
  - the shipped tabs budget loop now tests `bytesOf(frame)`
  - `bmImporting`, `bmUrlSet` (with the tri-state contract written out), `onBookmarkEvent`
  - five `chrome.bookmarks.on*` registrations plus the two import listeners, all at top level inside `if (chrome.bookmarks) { … }`
  - `buildAndSendAll` — the single debounce target and on-open push, carrying the `bm.state` send + counts-only log
  - `capBmTitle` and `buildBmSnapshot`

## Decisions Made

- **Where the send lives.** Task 2 step 4 says `buildAndSendAll` "sends the `bm.state` frame"; task 3 step 7 says `buildBmSnapshot` owns a send path "exactly like `buildAndSend` does". Both cannot be literally true. Resolved in favour of task 2's wording: `buildBmSnapshot` is a pure builder (`{frame, urls, count}` or `null`), and `buildAndSendAll` does the OPEN-state check, the try/catch and the log. The final file contains everything both tasks specify; only the function boundary between them moved. This also has a commit-hygiene benefit — see the deviation below.
- **A capped-out node's children are not enqueued.** When `nodes.length >= MAX_BM_NODES` the node is skipped and its `parentId` recorded, but its subtree is never pushed onto the queue. Enqueuing them would grow the frontier with nodes that can never be emitted and would add `dropped` entries for parents that were themselves never emitted, inflating the flag-nowhere edge case for no benefit.
- **The known truncation edge is documented in-file, not worked around.** If a dropped node's own parent was also dropped, the per-folder `truncated` flag lands nowhere; the snapshot-level flag is what stays honest. Chasing per-folder honesty up a dropped ancestor chain would mean re-emitting ancestors, which the budget is precisely out of.
- **`grep -c "MAX_BM_TITLE"` returns 3, not the criterion's "2 or more".** Criterion satisfied (declaration + the `capBmTitle` doc comment + the slice).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical] `capBmTitle` trims a trailing lone surrogate after the title cap**

- **Found during:** Task 3 (the byte-budget harness run)
- **Issue:** `(n.title || "").slice(0, MAX_BM_TITLE)` cuts on UTF-16 code units. A title where an emoji straddles character 48 is split in half, leaving a lone high surrogate; `JSON.stringify` then emits a bare `"\ud83d"` escape. serde_json rejects a lone leading surrogate as a hard decode error, and 11-02 made `bm.state` ingest **strict** — a parse failure keeps the last good tree. So exactly one emoji-decorated bookmark title landing on the cap boundary would cost the phone its entire bookmark tree, permanently and silently, with the extension visibly connected. `TextEncoder` independently confirms the corruption: the lone surrogate encodes as the U+FFFD replacement bytes `EF BF BD`.
- **Fix:** `capBmTitle(s)` slices as before, then drops the last code unit when it is in the `0xD800..0xDBFF` high-surrogate range. Titles ending on an intact pair keep all 48 chars; a straddling title yields 47.
- **Files modified:** `extension/background.js`
- **Verification:** harness — straddling title 47 chars, intact-pair title 48 chars, no lone-surrogate escape anywhere in the serialized frame, frame round-trips through `JSON.parse`/`JSON.stringify`, no U+FFFD emitted
- **Committed in:** `1634fdb` (Task 3 commit)

**2. [Rule 2 - Missing critical] Truncation flags applied before the byte measurement**

- **Found during:** Task 3 (writing the drop loop)
- **Issue:** The plan's step 5/6 order is: run the byte-measured drop loop, THEN add `truncated: true` to flagged nodes and to the payload, then re-serialize. Those flags cost ~18 bytes per flagged node plus ~20 for the payload key — which can push a frame that had *just* fit back over 57 344, defeating the loop whose entire purpose is guaranteeing the frame fits. The plan's own must-have ("a bookmark tree of any size produces a frame under 56 KB") would not hold.
- **Fix:** The serialization is a closure that applies the current `dropped` flags every time it runs, and the drop loop re-runs it. Each iteration strictly removes one node and `dropped` only grows, so the loop terminates and the measured frame is exactly the frame that ships. Identical control shape to the plan's, one level of indirection added.
- **Files modified:** `extension/background.js`
- **Verification:** harness CJK flood — final frame with both flag levels set measures 57 172 ≤ 57 344
- **Committed in:** `1634fdb` (Task 3 commit)

**3. [Rule 3 - Blocking] `buildAndSendAll`'s bookmark leg wrapped in a try/catch**

- **Found during:** Task 2 (introducing `buildAndSendAll` one commit before `buildBmSnapshot` exists)
- **Issue:** The plan has task 2 introduce a `buildAndSendAll` that calls task 3's `buildBmSnapshot`. `node --check` only parses, so nothing catches it — but at task 2's commit that call is a `ReferenceError` at runtime, and since `buildAndSendAll` is now the debounce target AND the on-open push, the commit would break the SHIPPED tab snapshot entirely.
- **Fix:** The bookmark leg sits in a try/catch that treats any throw as "unreadable" — `bmUrlSet = null`, no frame, then `await buildAndSend()` runs normally. This is not scaffolding to be removed: it is the same degradation posture the plan mandates for a failed `getTree()`, applied at the caller boundary, and it stays in the final file. Master's tab path was green at every commit.
- **Files modified:** `extension/background.js`
- **Verification:** `git show 931fc4c:extension/background.js` reasoning plus the final harness — an unreadable tree returns `null` and the tab path is untouched
- **Committed in:** `931fc4c` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (2 missing-critical, 1 blocking)
**Impact on plan:** All three protect invariants the plan itself declares (the 56 KB must-have, the strict-decode contract 11-02 landed, and not regressing the shipped tabs path). No scope added, no scope dropped; every declared artifact and every grep gate is satisfied.

## Issues Encountered

- **No JS test runner exists in this repo**, so `buildBmSnapshot` was exercised through a throwaway node harness in the scratchpad that extracts the function source and evaluates it against a stubbed `chrome.bookmarks`. That harness is not committed and is not a regression test — it is how the two Rule-2 defects above were found. The standing coverage remains the three in-plan node assertions plus UAT-3/UAT-11 at the 11-12 gate.
- **`git diff -U0` regression containment on the shipped tabs loop was checked explicitly** and is clean: one changed line (`frame.length` → `bytesOf(frame)`) plus one added comment line. The icon-stripping body, the `MAX_FRAME_BYTES` bound and the loop's exit condition are byte-identical to the pre-edit file.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-03 (info disclosure, element shape) | mitigate | Element carries `id`/`parentId`/`title` + four optional flags; `n.url` reaches only a module-local `Set`. Automated `url leaked into a bm element` gate green; a real serialized frame contains neither `"url"` nor `"icon"` |
| T-11-02 (info disclosure, logging) | mitigate | The one new log line emits node count and byte size. The `getTree` failure log carries `e.message` only, no node data. File header extended to name bookmark titles and urls |
| T-11-07 (DoS, 56 KB frame budget) | mitigate | `bytesOf` in BOTH loops; `MAX_BM_NODES` caps the walk before serialization; the drop loop pops whole nodes until the flagged frame fits. Proven on a 900-node CJK+emoji tree |
| T-11-11 (DoS, import storm) | mitigate | `bmImporting` gate; `onImportEnded` schedules exactly one snapshot |
| T-11-12 (info disclosure, widened permission) | accept | `bookmarks` declared in `permissions`; `optional_permissions` absent (grep-gated) — structurally impossible in a background-only extension with no gesture surface. Egress stays loopback-only |
| T-11-04 (tampering, subtree wipe) | mitigate | `removeTree` appears zero times anywhere under `extension/` (comment-stripped grep) |
| T-11-SC (supply chain) | mitigate | Zero packages; no `package.json`, no build step. `chrome.bookmarks` and `TextEncoder` are browser built-ins |

**Threat flags:** none. The only new surface is the `bm.state` egress already in the register.

## Known Stubs

None. Every symbol this plan declares is fully wired and reachable at runtime.

Two things are absent **by design**, both belonging to 11-06: the `bm.open`/`bm.star`/`bm.unstar`/`bm.remove` command handlers in `socket.onmessage`, and `el.bookmarked` on the tab element. `bmUrlSet` is therefore maintained here but not yet read — that is the declared hand-off, not a stub.

## User Setup Required

**One manual step at UAT time, not now:** the extension must be reloaded from `chrome://extensions` for the widened `permissions` array to take effect, and Chrome may present the new bookmarks permission for approval on reload. 11-12 owns recording what Chrome actually does (UAT-1) and the release-facing README wording.

## Next Phase Readiness

- **11-06 (extension command handlers + `el.bookmarked`) is unblocked and has everything it needs here:** `bmUrlSet` is a `Set<string>` of exact bookmark URLs, rebuilt on every debounce ahead of `buildAndSend()`, and `null` exactly when the tree was unreadable. The D-11 tri-state rule to implement is `if (bmUrlSet !== null && tab.url) el.bookmarked = bmUrlSet.has(tab.url);` — all-or-nothing across the snapshot, never a per-tab mix.
- **The srv→ext command contract 11-06 must decode is already pinned by 11-02's socket tests:** `bm.open`/`bm.remove` carry `nodeId` as a JSON **string**, `bm.star`/`bm.unstar` carry `tabId` as a JSON **number**. 11-06 also owns `bookmarksBarId()` (Pitfall 6: `folderType === 'bookmarks-bar'`, never the literal `"1"`), the `if (!node.url) return;` folder guard on `bm.open` (Pitfall 9), and the CI-visible `removeTree` guard test.
- **Deferred, logged, not fixed:** the shipped group-title cap has the same lone-surrogate hazard `capBmTitle` fixes for bookmarks. Pre-existing, on the leniently-parsed `groups` array, out of this plan's scope — recorded in `deferred-items.md`.
- **UAT hand-off:** UAT-3 in 11-12 must record the real post-edit frame byte size from the SW console and confirm no `[tab-bridge] disconnected` follows a snapshot; UAT-11 regression-checks the tab list on device. This plan does **not** claim the tabs path is verified — `bytesOf(s) >= s.length` for all inputs, so the change can only strip more icons, never fewer, but that reasoning is not a device test.

## Self-Check: PASSED

Both claimed files exist on disk and carry the claimed symbols (`"bookmarks"` in `permissions`, `MAX_BM_NODES = 500`, `MAX_BM_TITLE = 48`, `function bytesOf`, `bytesOf(frame)` ×2, `frame.length` ×0, `let bmImporting = false`, `let bmUrlSet = null`, `function onBookmarkEvent`, `setTimeout(buildAndSendAll` ×1, `setTimeout(buildAndSend,` ×0, seven `chrome.bookmarks.on*` registrations inside the top-level guard, `async function buildBmSnapshot`, `tree[0].children` seed, `removeTree` ×0). All three task commits (`84d6f54`, `931fc4c`, `1634fdb`) are present in git history on `master`. All three in-plan node assertions print their `ok` line and exit 0. Three-suite gate re-run at plan close: `cargo test --workspace` 192 passed / 0 failed, `flutter test` 547 passed, `dart test` 12 passed. Working tree clean.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
