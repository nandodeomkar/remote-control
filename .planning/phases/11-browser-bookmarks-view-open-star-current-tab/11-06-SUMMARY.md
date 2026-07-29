---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 06
subsystem: extension
tags: [chrome-extension, mv3, service-worker, bookmarks, commands, tri-state, d-10, d-11, d-14, source-guard, privacy]

# Dependency graph
requires:
  - phase: 11-05
    provides: bmUrlSet (the module-local exact-URL Set, null when the tree was unreadable), buildAndSendAll as the single debounce target, capBmTitle, bytesOf, the chrome.bookmarks.on* listener block and the bookmarks manifest permission
  - phase: 11-02
    provides: the srv-to-ext relay that emits the four bm.* command frames with nodeId typed string and tabId typed number
  - phase: 11-03
    provides: the phone-facing codec + router classification that puts those four commands on the executor-bound (pause-dropped) path
  - phase: 11-01
    provides: SPEC section 7's tri-state TabEl.bookmarked paragraph and fixture tabs/09-tabs-changed-bookmarked.json
provides:
  - TabEl.bookmarked — explicit true/false on every tab with a url whenever the bookmark tree was readable, key absent from EVERY tab when it was not (D-11 tri-state)
  - bookmarksBarId() — locale-safe bookmarks-bar resolution via folderType, the D-10 replacement for the hardcoded id "1"
  - The four bm.open / bm.star / bm.unstar / bm.remove command arms in the onmessage switch, each fire-and-forget with fail-closed input guards
  - server/server-core/tests/extension_guard.rs — four CI-visible source-level guards inside the existing cargo test --workspace gate
  - The star-known count on the snapshot log (a count, never a title, never a url)
affects: [11-08, 11-09, 11-10, 11-11, 11-12]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A source-level invariant with no test runner for its language gets a comment-stripped Rust integration test — CI-visible with zero new tooling"
    - "A guard test that documents its own ban must strip comments, or the clearer the comment the redder the test"
    - "An optional-API namespace is guarded at the message-dispatch boundary, not per-arm: a bare chrome.bookmarks.get() throws SYNCHRONOUSLY past every terminal .catch"

key-files:
  created:
    - server/server-core/tests/extension_guard.rs
  modified:
    - extension/background.js

key-decisions:
  - "Task 1's `grep -c \"bookmarks.search(\" == 0` and `grep -c \"url:\" == 0` criteria are TASK-TIME criteria, not plan-close criteria: task 2 legitimately adds search({url}) for unstar and three url: Chrome-API argument sites. Both were verified 0 at the task-1 commit and are structurally superseded by task 2; the durable invariant (no search inside buildAndSend, no url on an emitted element) is proven by the comment-stripped node assertion and by extension_bm_elements_carry_no_url"
  - "The plan's own action text mandates a comment naming chrome.bookmarks.search({url}) as the thing NOT to do per-tab, which alone makes the raw grep non-zero — the criterion contradicts the instruction that precedes it. Kept the honest comment; the comment-stripped gate is the real one"
  - "bookmarksBarId() falls back to roots[0] then to null, and bm.star does NOTHING on null rather than creating an unparented bookmark — an unpredictable landing folder is worse than a silent no-op the phone self-heals from"
  - "The el.url guard is deliberately narrow (el.url plus its two bracket forms) and its comment enumerates the legitimate tab.url / n.url / node.url reads by name, so a future author fixes a real leak instead of deleting a test that trips on correct code"
patterns-established:
  - "Mutation-prove every source guard: all four extension_guard tests were driven RED by a deliberate three-line violation plus a manifest edit, then reverted — a first-run green is exactly the signal an UNWIRED guard also produces"

requirements-completed: []

# Metrics
duration: 6min
completed: 2026-07-29
---

# Phase 11 Plan 06: Extension bookmark commands and the tri-state star Summary

**The extension tier is closed: every tab now carries an honest tri-state `bookmarked` flag computed by raw exact-URL set membership, all four `bm.*` commands execute against untrusted phone input with fail-closed guards and locale-safe bookmarks-bar resolution, and D-14's "a subtree wipe is structurally impossible" is now a test that fails the Rust suite rather than a comment.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-07-29T17:31:08Z
- **Completed:** 2026-07-29T17:37:10Z
- **Tasks:** 3
- **Files created:** 1
- **Files modified:** 1

## Accomplishments

- **The star can never misreport (D-11).** One assignment line, `el.bookmarked = bmUrlSet.has(tab.url)`, guarded by `bmUrlSet !== null && tab.url`. All-or-nothing across the snapshot: when 11-05's builder returned `null` the key is absent from EVERY tab, so the phone renders no star at all instead of an empty star on a page that IS bookmarked. A tab with no `url` (discarded) also gets no key — unknown is the honest answer for that one row. The divergence from the skip-when-absent `icon`/`groupId` precedent is written out in-file so nobody "optimizes" the explicit `false` into a skip.
- **Zero URL normalization, and the comment says why it is about blast radius rather than fidelity.** No fragment stripping, no query stripping, no scheme unification, no trailing-slash fixing — verified by the comment-stripped assertion that `toLowerCase()`, `replace(/#`, and `split('#')` appear nowhere. Widening "matches" here would widen `bm.unstar`, which deletes EVERY match, letting an unstar on a base URL destroy a deliberately-kept fragment-specific bookmark.
- **No per-tab `search({url})` in the snapshot path.** The URL set is a free by-product of the `getTree()` walk `buildBmSnapshot` already does; 50 IPC round-trips inside a 200 ms debounce would double worst-case snapshot latency for identical semantics. Proven by bounding `buildAndSend()` and asserting the file's single `bookmarks.search(` call lives outside it, in the `bm.unstar` arm.
- **`bookmarksBarId()` resolves by `folderType === "bookmarks-bar"`** — never the hardcoded `"1"` (D-10 forbids it and Chrome does not guarantee root numbering across profiles) and never a title match (root titles are localized; "Bookmarks bar" does not exist on a German or Japanese Chrome, and the miss files silently into "Other bookmarks").
- **`bm.open` fails closed on a folder id.** `chrome.bookmarks.get(p.nodeId)` → `if (!node.url) return;` before `tabs.create`. Without it, `tabs.create({url: undefined})` opens the new-tab page: a confusing no-op instead of a visible failure. `p.nodeId` is an opaque untrusted string from an authed but remote LAN peer, so unknown ids and foreign-profile ids reject into the terminal `.catch` (T-11-10).
- **`bm.unstar` deletes every exact match with per-node error isolation.** `unmodifiable` nodes are skipped (T-11-05) and each `remove` carries its own `.catch` — a managed node's modify-managed rejection and a concurrently-deleted node's no-node rejection must not abort the rest, or the star stays lit with some copies already gone. `search({url})` matches verbatim and folders have no url, so D-11's "delete every match" cannot interact with D-14 at all.
- **D-14 is now enforced, not asserted.** `server/server-core/tests/extension_guard.rs` runs inside `cargo test --workspace` with no new tooling. All four guards were **mutation-proven RED** (below) rather than trusted on a first-run green.
- **Three-suite baseline held:** `cargo test --workspace` **201 passed / 0 failed** (197 baseline + the 4 new guards), `dart test` 13 passed, `flutter test` 547 passed.

## Task Commits

1. **Task 1: Tri-state TabEl.bookmarked from the shared URL set** — `2497d22` (feat)
2. **Task 2: bm.* command handlers and locale-safe bookmarks-bar resolution** — `6a17e5a` (feat)
3. **Task 3: Source guard — removeTree is never called and no url reaches a bm element** — `6e89db4` (test)

## Files Created/Modified

- `server/server-core/tests/extension_guard.rs` *(new)* — `EXT_BACKGROUND` / `EXT_MANIFEST` resolved with the `CARGO_MANIFEST_DIR` idiom cloned from `tests/fixtures.rs`; `ext_code_lines()` strips every line whose trimmed form starts with `//` or `*`; four tests (`extension_never_calls_remove_tree`, `extension_never_hardcodes_bookmarks_bar_id`, `extension_bm_elements_carry_no_url`, `extension_declares_bookmarks_permission`), each with a failure message that names the decision it defends and tells the reader what to do instead.
- `extension/background.js` —
  - the tri-state `el.bookmarked` assignment plus its divergence / no-normalization / no-per-tab-search rationale in `buildAndSend`'s element loop
  - the snapshot log extended with a `star-known` count
  - the `msg.t.startsWith("bm.") && !chrome.bookmarks` dispatch guard
  - four `case "bm.*"` arms in the `onmessage` switch
  - `bookmarksBarId()` in a new "Bookmark command support" section

## Decisions Made

- **Where the `chrome.bookmarks`-absent guard lives.** One line at the dispatch boundary rather than four per-arm guards. `bm.star` and `bm.unstar` start with `chrome.tabs.get`, so their bookmarks access is already inside a `.then` and reaches the terminal `.catch`; **`bm.open` and `bm.remove` touch `chrome.bookmarks` synchronously** and would throw a `TypeError` straight out of `onmessage`. See deviation 1.
- **`bookmarksBarId()` returns `null` rather than guessing.** Falls back `folderType` → `roots[0]` → `null`; `bm.star` creates nothing on `null`. An unparented `create` either rejects or lands the bookmark somewhere the owner cannot predict, and the phone has no error channel to tell them.
- **The `el.url` guard is narrow on purpose.** It matches `el.url`, `el["url"]`, `el['url']` and nothing else, and its comment enumerates by name the legitimate reads (`tab.url`, `n.url`, `node.url`) and the legitimate Chrome-API argument sites (`url: tab.url`, `url: node.url`). A bare `"url"` scan would trip on correct code, and the next author would delete the test instead of fixing the bug it exists to catch.
- **Comment stripping is load-bearing in the guard.** The file is *supposed* to document that `removeTree` is banned and that `"1"` is forbidden. Without stripping, the better the documentation the redder the test — the guard would punish exactly the behaviour it wants.

## Criterion Discrepancies

Recorded per the standing instruction to satisfy intent and document rather than contort code to hit a wrong number. Three this plan, all in task 1, all of the same shape: **task-time criteria evaluated at plan close.**

| Criterion | Stated | Actual at plan close | Resolution |
|---|---|---|---|
| `grep -c "bookmarks.search(" extension/background.js` | 0 | **1** | Task 2 legitimately calls `search({url})` in the `bm.unstar` arm — the plan's own task-2 action text mandates it. Verified 0 at the task-1 commit. Durable invariant re-proven with a scoped check: exactly one call in the file, and **zero inside `buildAndSend()`** (bounded from `async function buildAndSend()` to `async function buildBmSnapshot()`). |
| `grep -v "^\s*//" \| grep -c "url:"` | 0 | **3** | Three Chrome-API *argument* sites added by task 2: `tabs.create({ url: node.url })`, `bookmarks.create({ …, url: tab.url })`, `bookmarks.search({ url: tab.url })`. None is a key on an emitted element. Verified 0 at the task-1 commit; the durable invariant is guarded by `extension_bm_elements_carry_no_url`. |
| `grep -v "^\s*//" \| grep -c "tabs: els"` | "still returns 1" | **2**, unchanged | Pre-existing: `{ tabs: els, groups }` appears on both the initial serialize and the icon-strip re-serialize. Baseline measured **2 before any edit**; the criterion's intent ("the tab payload shape is otherwise unchanged") holds — the count did not move. |

A fourth, milder note: `grep -c "catch(() => {})"` returns **8** against a floor of 7. Seven are code lines (2 pre-existing + 5 added: four command arms plus the per-node unstar removal); the eighth is the `bm.*` section comment that quotes the idiom. Both readings clear the floor.

The recurring root cause across this phase is unchanged: **`grep -c` counts LINES, and a criterion written against the code often collides with a comment the same plan instructed the executor to write.**

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical] Optional-API guard so a withheld `bookmarks` permission cannot throw out of `onmessage`**

- **Found during:** Task 2
- **Issue:** The plan specifies four arms cloning the `tabs.activate` shape, each ending in a terminal `.catch(() => {})`. That catch only covers *rejections*. When `chrome.bookmarks` is undefined — the permission was withheld at the `chrome://extensions` reload prompt 11-05 flagged for UAT-1, or the browser is a non-Chromium fork — `chrome.bookmarks.get(p.nodeId)` and `chrome.bookmarks.remove(p.nodeId)` throw a **synchronous `TypeError`** before any promise exists, escaping past the terminal catch and out of the `onmessage` handler. Every `bm.*` frame from the phone would then raise an uncaught error in the service worker. The rest of the file already treats this exact namespace as optional (`if (chrome.bookmarks) { … }` around the listener block, cloned from `if (chrome.tabGroups)`), so the arms were the one place the posture was missing.
- **Fix:** One line after the payload extraction: `if (msg.t.startsWith("bm.") && !chrome.bookmarks) return;`. Covers all four arms without disturbing the shape the plan mandates. No reply is owed — the family is fire-and-forget and the phone already knows the tree is unreadable, because no `bm.state` frame was ever sent and the server keeps `BookmarksState.connected` false.
- **Files modified:** `extension/background.js`
- **Verification:** `node --check` exits 0; the task-2 comment-stripped assertion prints `commands ok`; `grep -c 'case "bm\.'` still returns 4 (the guard is not a case arm)
- **Committed in:** `6a17e5a` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (missing-critical). No Rule 4 architectural decision was reached and no checkpoint was hit.
**Impact on plan:** Additive and inside the plan's own degradation posture — an absent `chrome.bookmarks` was already required to mean "unreadable, do nothing" everywhere else in the file. Every declared artifact and every symbol the plan names is present; no scope added or dropped.

## Verification Evidence

- `node --check extension/background.js` — exits 0
- Task 1 comment-stripped assertion — `bookmarked ok` at the task-1 commit; scoped re-run at plan close prints `bookmarked ok (scoped)` (see Criterion Discrepancies)
- Task 2 comment-stripped assertion — `commands ok`
- `cargo test -p server-core --test extension_guard` — 4 passed / 0 failed
- `cargo test --workspace` — **201 passed / 0 failed** (baseline 197 + 4)
- `dart test` — 13 passed; `flutter test` — 547 passed
- Grep gates: `case "bm\.` **4**; `function bookmarksBarId` **1**; `folderType === "bookmarks-bar"` **1**; comment-stripped `removeTree` **0**; `el.bookmarked` **1**; `if (!node.url) return` **1**; `catch(() => {})` **8** (floor 7); `CARGO_MANIFEST_DIR` in the guard **2**; `starts_with("//")` in the guard **1**

### The deliberate RED experiment (mandated, performed, reverted)

Appended to `extension/background.js`:

```
chrome.bookmarks.removeTree("1");
chrome.bookmarks.create({ parentId: "1" });
el.url = "leak";
```

and removed `"bookmarks"` from `extension/manifest.json`'s `permissions`. Result: **all four guards failed simultaneously** — `extension_never_calls_remove_tree`, `extension_never_hardcodes_bookmarks_bar_id`, `extension_bm_elements_carry_no_url`, `extension_declares_bookmarks_permission` — each with its own decision-naming message (`test result: FAILED. 0 passed; 4 failed`). Reverted with `git checkout -- extension/background.js extension/manifest.json`; `git status --short` then showed only the new untracked test file, and the guards returned 4/4 green. The experiment went one step beyond the plan's requirement (which named only `removeTree`) because a first-run green is exactly the signal an *unwired* guard also produces — the same reasoning 11-03 applied to its fixture family.

## Threat Model Coverage

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-11-10 (tampering, `bm.open` on an untrusted `nodeId`) | mitigate | `chrome.bookmarks.get(p.nodeId)` → `if (!node) return;` → `if (!node.url) return;` before `tabs.create`. Folder ids, unknown ids and foreign-profile ids all fail closed; terminal `.catch(() => {})` |
| T-11-04 (tampering, subtree wipe) | mitigate | `bm.remove` calls only `chrome.bookmarks.remove`; `removeTree` appears **zero** times in comment-stripped source and `extension_never_calls_remove_tree` fails `cargo test --workspace` if it ever does — **mutation-proven RED**. Chrome's folder-not-empty rejection is the second backstop, the phone-side `count == 0` affordance gate (11-10) the third |
| T-11-05 (tampering, managed / root bookmark) | mitigate | `bm.unstar` skips `unmodifiable` nodes; `bm.remove` relies on Chrome's modify-managed and modify-special rejections. Every removal is individually caught so one rejection cannot abort the batch |
| T-11-06 (tampering, unstar blast radius) | mitigate | Raw exact string equality against `tab.url` with zero normalization — comment-stripped assertion gates `toLowerCase()` / `replace(/#` / `split('#')` at 0. `search({url})` matches verbatim and cannot return folders |
| T-11-02 (info disclosure, command-arm logging) | mitigate | No arm logs anything at all. The only new log output is an integer `star-known` count appended to the existing counts-only snapshot line |
| T-11-03 (info disclosure, `el.bookmarked` computation) | mitigate | `bmUrlSet` stays module-local and is never serialized; only a boolean derived from it reaches the wire. `extension_bm_elements_carry_no_url` guards the element shape at source level — **mutation-proven RED** |
| T-11-01 (info disclosure, tri-state misreport) | mitigate | `bmUrlSet === null` omits the key from every tab; an unreadable tree renders no star rather than a false negative. One assignment site, guarded |
| T-11-SC (tampering, supply chain) | mitigate | Zero packages added. `Cargo.toml` untouched — the guard uses `serde_json`, already a `server-core` dependency. No JS test runner introduced |

**Threat flags:** none. The four `bm.*` command arms are the surface already in the register; no new endpoint, auth path, file access pattern or trust-boundary schema change was introduced.

## Known Stubs

None. Every symbol this plan declares is fully wired and reachable at runtime.

The one thing intentionally *not* here: nothing in this plan renders or gates a star — `TabEl.bookmarked` now ships on the wire and 11-08/11-10 own the phone-side `optimisticStars` / affordance-gate consumption. That is the declared hand-off, not a stub.

## Issues Encountered

- **Still no JS test runner in this repo**, so the extension edits carry no unit coverage of their own. The standing gates are `node --check`, the two comment-stripped node assertions, the four Rust source guards, and UAT at the 11-12 gate. The command arms in particular are **source-verified only** — no code path in this plan has executed against a real `chrome.bookmarks`.
- **The `catch(() => {})` floor of 7 is now exactly met by code lines.** Worth knowing for whoever touches this file next: converting any arm to `async`/`try` without keeping the idiom drops the count below the floor.

## User Setup Required

None new. 11-05's standing item is unchanged and still belongs to UAT: the extension must be reloaded from `chrome://extensions` for the `bookmarks` permission to take effect, and Chrome may prompt for approval on reload. The dispatch guard added here (deviation 1) is what makes the *declined* branch of that prompt behave sanely instead of throwing on every `bm.*` frame.

## Next Phase Readiness

- **The extension tier is complete for this phase.** `bm.state` snapshots (11-05) and all four commands (here) are wired; nothing further is owed to `extension/` unless UAT finds a defect. 11-12 owns the manifest `version` bump and the release-facing README wording.
- **11-08 (Flutter app state) can consume `TabInfo.bookmarked` as a real tri-state** — `bool?` where `null` genuinely means UNKNOWN and must render no star button, not an empty one. SPEC section 7 and fixture `tabs/09-tabs-changed-bookmarked.json` are the contract; the extension now produces exactly that shape.
- **11-10 (bookmarks section / affordance gate) inherits one obligation from D-14's defence in depth:** the phone-side `count == 0` gate on folder deletion is the *first* of the three backstops named in the `bm.remove` comment. The extension only guarantees that a wipe is impossible, not that a confusing partial failure is.
- **Any future author who needs recursive bookmark deletion must change the decision, not the code.** `extension_never_calls_remove_tree` will fail `cargo test --workspace` and its message says so explicitly, including that Chrome offers no undo path the phone can reach.
- **Deferred, unchanged:** the shipped 32-char GROUP-title cap still has the lone-surrogate hazard `capBmTitle` fixes for bookmarks. Pre-existing, on the leniently-parsed `groups` array, explicitly out of this plan's scope — it remains in `deferred-items.md`.

## Self-Check: PASSED

Both claimed files exist on disk and carry the claimed symbols: `extension/background.js` — `el.bookmarked = bmUrlSet.has(tab.url)` ×1, `async function bookmarksBarId` ×1, `folderType === "bookmarks-bar"` ×1, `case "bm.` ×4, `if (!node.url) return` ×1, comment-stripped `removeTree` ×0, `star-known` ×1; `server/server-core/tests/extension_guard.rs` — 4 `#[test]` fns, `CARGO_MANIFEST_DIR` ×2, `starts_with("//")` ×1. All three task commits (`2497d22`, `6a17e5a`, `6e89db4`) are present in git history on `master`. Three-suite gate at plan close: `cargo test --workspace` 201 passed / 0 failed, `dart test` 13 passed, `flutter test` 547 passed. The deliberate `removeTree` mutation was performed, drove all four guards RED, and was reverted — `git status --short` clean of source changes afterwards.

---
*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Completed: 2026-07-29*
