---
phase: 11-browser-bookmarks-view-open-star-current-tab
verified: 2026-07-31
verifier: gsd-verifier (goal-backward, adversarial)
status: passed
score: 7/7 goal clauses verified · 14/14 decisions covered
head: 58de2892414a82cddca055bb640fe1c4133d06db
acceptance_surface: D-01..D-14 (11-CONTEXT.md) — no REQ-IDs mapped
gaps: []
acknowledged_deferrals: 4  # deferred-items.md — item 1 CLOSED by quick 260731-d45; items 2,3,4 open by owner decision
---


# Phase 11 Verification — Browser bookmarks: view, open, star current tab

**Phase Goal:** The phone can browse the PC browser's bookmark tree by folder, open a bookmark in a
new tab, star/unstar any tab, and delete a bookmark or an empty folder — delivered as a second
segment on the existing Browser screen (protoVersion 1.6), with URL resolution staying extension-side
so no `url` field ever crosses the phone-facing wire.

**Method:** goal-backward. Each clause was traced to the delivering code and read. SUMMARY.md claims
were not accepted as evidence for any row below.

---

## 1. Goal clause → delivering code

| # | Goal clause | Delivering code | Verdict |
|---|-------------|-----------------|---------|
| 1 | browse the bookmark tree **by folder** | `bookmarks_store.dart:149-258` — `BookmarksNotifier` owns `_currentFolderId` + `_backStack` **on the notifier, not in the snapshot**, so a pushed `bm.changed` cannot reset position; `enterFolder`/`goBack` at :231-244 send nothing on the wire (D-06). `_view()` :190-210 buckets by `parentId` in one pass with a **stable** folders-then-links partition. `bookmarks_section.dart:157-182` renders `currentChildren`; `:190-226` the depth>0 folder bar with a back control that stays live when unauthed. `browser_screen.dart:576-580` routes Android system back into `goBack()` via `PopScope`. | ✓ VERIFIED |
| 2 | **open a bookmark in a new tab** | `bookmarks_store.dart:250` → `BmOpenMsg(nodeId:)`; `router.rs:280-283` `Msg::BmOpen → exec.bookmarks.open(&p.node_id)`; `ext.rs:270` relays `{"t":"bm.open","p":{"nodeId":…}}`; `background.js:166-175` `chrome.bookmarks.get(p.nodeId)` → guards `if (!node.url) return` → `chrome.tabs.create({url: node.url})`. The folder guard is real, not commentary — a folder id fails closed instead of silently opening the new-tab page. | ✓ VERIFIED |
| 3 | **star/unstar any tab** | Star slot on **every** row: `browser_screen.dart:1084-1120` — 48x48 nested `InkWell` inside the row's, tri-state (`null` renders no slot at all), `fill: 1/0` as the state signal. `_onStarTab` :471-487 is asymmetric by design: add is instant + optimistic; remove opens `confirmDestructive` FIRST and returns on `!confirmed \|\| !mounted`. `tabs_store.dart:167-180` optimistic overlay `_optimistic`, `bookmarkedFor` :56. Extension truth: `background.js:196-220` `bookmarks.search({url: tab.url})` → per-node `remove()` with a per-node `.catch` so one managed-node rejection cannot abort the rest. | ✓ VERIFIED |
| 4 | **delete a bookmark or an empty folder** — the clause that FAILED on device | **Fix is in shipped code.** `bookmarks_section.dart:344-348`: `onTap: _activate`, `onTapDown: (_) => _flash()`, `onLongPress: deletable ? _confirmDelete : null`. The split is real — `_flash()` :289-294 is visual only, `_activate()` :302-308 holds the drill-in/open and hangs off `onTap`, so it can only fire once the tap has **won the arena**. Affordance gate `BookmarksViewState.isDeletable` :107-111 (locked ⇒ never; folder ⇒ `count == 0`; missing count read conservatively as non-empty). Confirm gate `_confirmDelete` :312-322 fires `onDelete` only on `confirmed == true`. | ✓ VERIFIED |
| 5 | a **second segment on the existing Browser screen** | `browser_segment.dart` — `BrowserSegment` enum + persisted store under a **new** prefs key `browser.segment` (:39), corrupt/throwing read degrades to `tabs` (:54-64). `browser_screen.dart:593-596` the bar; :601-621 the **single** swapped region; :629-639 the macro grid moved into a pinned footer *outside* the scroll region — D-02's identical rect therefore holds **by construction**, and is pinned by test at `browser_screen_test.dart:844-889` (`getRect(BrowserMacroGrid)` equality across switches). | ✓ VERIFIED |
| 6 | **protoVersion 1.6** | `session.rs:65` `SERVER_PROTO_VERSION = "1.6"`, single-sourced; re-exported `transport/mod.rs:22`; consumed by `beacon.rs:56`. `protocol/SPEC.md:3,32,41`. Beacon fixture `fixtures/beacon/01-valid.json` = `"1.6"`. **1.0–1.5 still accepted:** `session.rs:554-583` rejects on MAJOR mismatch only — the Dart client still announces `1.1` (`version.dart:11`) and is accepted, which is the shipped 1.2→1.5 posture, not a regression. | ✓ VERIFIED |
| 7 | **no `url` field ever crosses the phone-facing wire** | Verified **structurally at three independent tiers**, not by trust — see §2 below. | ✓ VERIFIED |

---

## 2. The security-shaped invariant, checked structurally

Three independent tiers each make a URL on the phone wire impossible. Any one of them failing is
caught by the other two.

| Tier | Mechanism | Evidence |
|------|-----------|----------|
| **Extension (source of truth)** | `buildBmSnapshot` `background.js:558-636` builds `el` with **exactly** `id`, `parentId`, `title`, then conditionally `folder`+`count`, `locked`, `truncated`. There is no `url` assignment anywhere in the object. URLs go to `urls.add(n.url)` (:601) — a **module-local `Set`** (`bmUrlSet`, declared :79) that is read only at :484 to compute the tri-state `bookmarked` flag and is **never serialized**. | read in full |
| **Server (structural drop)** | `ext.rs:364` `serde_json::from_value::<Vec<BmNode>>`. `BmNode` (`executors/mod.rs:163-176`) has fixed fields and no catch-all — serde **discards** any unknown key. So even a compromised or future extension emitting `url` cannot get it past the relay. | read in full |
| **Both codecs + fixtures** | Rust `BmNode` and Dart `BmNode` (`json_codec.dart:317-351`) are field-for-field identical and neither has a url. Shared golden fixtures `protocol/fixtures/bookmarks/01-09` contain **zero** `url` keys (the only "url" strings are prose in `description`). Registered in both hard-coded harnesses: `tests/fixtures.rs:187-196` and `test/fixture_test.dart:218-219`. | grepped + read |

**Automated backstop, executed by this verification.** `server/server-core/tests/extension_guard.rs`
asserts against `background.js` source text. This was worth re-running independently: the orchestrator's
"`server/` untouched by quick 260731-d45" argument does **not** cover these tests, because they read
`extension/background.js`, which that task **did** modify (the `capTitle` refactor).

```
cargo test --test extension_guard    →  4 passed; 0 failed
  extension_bm_elements_carry_no_url        ok    (T-11-03)
  extension_never_calls_remove_tree         ok    (D-14)
  extension_never_hardcodes_bookmarks_bar_id ok   (D-10)
  extension_declares_bookmarks_permission   ok
```

`extension/manifest.json` confirms `"permissions": ["tabs","tabGroups","favicon","alarms","bookmarks"]`.

---

## 3. D-01 … D-14 coverage

| # | Decision | Delivering code | Status |
|---|----------|-----------------|--------|
| D-01 | Tabs \| Bookmarks segmented control; swaps only the list region | `browser_screen.dart:593-621` — one ternary over one region; no route, no screen | ✓ |
| D-02 | Macro grid pinned in BOTH segments, no shift | `browser_screen.dart:629-639` (outside the scroll region); rect equality test `browser_screen_test.dart:844-889`; confirmed on device UAT-11 | ✓ |
| D-03 | Lazy prime on first Bookmarks display | `_maybePrimeBookmarks` `browser_screen.dart:501-507` — flag flips **before** the post-frame callback, so two builds in one frame cannot double-send | ✓ |
| D-04 | Open leaves the user in Bookmarks, same folder | `bookmarks_store.dart:250` `open()` touches neither `_currentFolderId` nor the segment; UAT-4 + B4 on device | ✓ |
| D-05 | Folder drill-down navigation | `enterFolder`/`goBack` + `_BmRow` folder branch | ✓ |
| D-06 | Whole tree in ONE `bm.state`; phone navigates locally; node cap + truncation story | `background.js:582-633` BFS + `MAX_BM_NODES=500` + a UTF-8 **byte**-measured budget loop; server belt `ext.rs:367`; phone-side copy `kBmTruncatedSnapshot`/`kBmTruncatedFolder` `bookmarks_section.dart:50,53` | ✓ |
| D-07 | No favicons on bookmark rows | `bookmarks_section.dart:326-328` folder/bookmark glyph only; BmEl has no `icon` field in either codec or any fixture | ✓ |
| D-08 | Top level lists all roots | `background.js:577` seeds the queue from `tree[0].children`, root `"0"` never emitted; phone treats `"0"` as the virtual top level (`bookmarks_store.dart:155`). *UAT-2 documented deviation:* Comet's `getTree()` withholds the synced root — the extension cannot emit a root the API never hands it; the frame matched `getTree()` exactly. Not a D-08 violation. | ✓ |
| D-09 | Trailing star on EVERY tab row | `browser_screen.dart:1084-1120`, nested recognizer; arena isolation pinned by widget test | ✓ |
| D-10 | Star files into bookmarks-bar root resolved via `getTree()`, never id `"1"` | `bookmarksBarId()` `background.js:655-661` matches on `folderType === "bookmarks-bar"` (stable enum, not a localized title), returns `null` rather than guessing; caller `:187` creates **nothing** on null. Guard test forbids the hardcoded id. **On-device proof:** UAT-5 ran on a profile where `other=371`, not `2` — a hardcoded-id implementation would have misfiled. | ✓ |
| D-11 | Truthful "anywhere" star; remove every match; confirm-gated | Exact `Set.has(tab.url)` with **no** normalization `background.js:483-484`; unstar removes every `search({url})` match `:196-219`; confirm gate `browser_screen.dart:477-484`. Tri-state absence = UNKNOWN = **no slot rendered** (`:1084`), so the star can never misreport | ✓ |
| D-12 | Optimistic fill, reconciled by the next push | `tabs_store.dart:99,167-180` `_optimistic` overlay, cleared on authoritative snapshot (:108,:135); `fill` unanimated; UAT-7 confirmed no flicker on device | ✓ |
| D-13 | Delete from inside the list, **same** confirm gate as unstar | One shared `confirmDestructive` (`bookmark_confirm.dart`) called by both `browser_screen.dart:477` (unstar) and `bookmarks_section.dart:313` (delete) — one deletion path, one safety story, no fork | ✓ |
| D-14 | Folders deletable only when empty; subtree wipe structurally impossible | Phone affordance gate `isDeletable` (`bookmarks_store.dart:107-111`); wire has no bulk/recursive form; `background.js:229` calls `chrome.bookmarks.remove` and the `removeTree` ban is **test-enforced**. Three Chrome-side backstops behind it (folder-not-empty, modify-special, modify-managed) | ✓ |

---

## 4. Wire plumbing (end-to-end, per command)

| Path | Phone | Codec | Router | Relay | Extension |
|------|-------|-------|--------|-------|-----------|
| `bm.list` | `primeList()` store:228 | json.rs:481 / json_codec.dart:1055 | **READ** — answered while paused, router.rs:263-273 | — | — |
| `bm.changed` | store `_onChange` | json.rs:482 | S→C only, router.rs:336 | authed-gated push arm session.rs:366-383 | `bm.state` ext.rs:362-378 |
| `bm.open` | store:250 | json.rs:483 | executor-bound router.rs:364 | ext.rs:270 | background.js:158-175 |
| `bm.star` | store:167 | json.rs:484 | executor-bound | ext.rs:273 | background.js:176-195 |
| `bm.unstar` | store:177 | json.rs:485 | executor-bound | ext.rs:276 | background.js:196-220 |
| `bm.remove` | store:256 | json.rs:486 | executor-bound | ext.rs:279 | background.js:221-230 |

Pause classification (SPEC §11) is correct and asymmetric as designed: `bm.list` is exempt, all four
commands are dropped while paused. Verified on device by UAT-10 — the list still loaded, the tap did
nothing. That is pause suppressing actuation without blinding observation.

`ext.rs` parses `bm.state` **strictly** (a bad `nodes` array discards the frame and keeps the last good
tree) while reading the snapshot-level `truncated` flag leniently. Correct: a half-parsed tree rendered
as a real one is a wrong answer, and the deferred-items record shows the team already understands the
cost of the opposite choice.

---

## 5. The UAT-8 failure — explicitly scored

**A row that failed, was fixed, and was re-verified is a PASS. Stating that rather than averaging it.**

- **2026-07-30:** UAT-8 FAILED (Failure B). D-14's empty-folder delete was unreachable by any gesture,
  and reaching a link's delete force-opened the link. Root cause: the action hung off `onTapDown`,
  which Flutter fires at `kPressTimeout` (100 ms) on **every** long press — 400 ms before
  `LongPressGestureRecognizer` can resolve. On a folder the resulting list swap destroyed the row first.
- **The fix is in the shipped code**, not just in the summary: `bookmarks_section.dart:344-348`.
- **The regression tests exist and are semantic**, which is the part that matters. The pre-existing
  suite already crossed the 100 ms deadline (`tester.longPress` pumps 600 ms) — what it never did was
  assert the navigation callback stayed **silent**. That one missing assertion is why the suite was
  green while the feature was broken. `bookmarks_section_test.dart:256-357` adds four tests that pin
  the semantics: long-press on an empty folder ⇒ confirm shown **and** `rec.entered` empty; long-press
  on a link ⇒ confirm shown **and** `rec.opened` empty; quick tap ⇒ action fires and **no** dialog;
  and a hold on a non-deletable folder ⇒ no confirm, drill-in **on release**.
- **11-13-03's own automated check re-run here:** `grep -c 'tap-DOWN fire' 11-UI-SPEC.md` = **0**,
  `grep -c 'flash ONLY'` = **2**. The contradictory gesture map that was the root cause is gone from
  the spec, so the defect cannot be re-implemented from the design doc.
- **2026-07-31 re-run:** B1–B6 all PASS, with B2's folder delete and B3's bookmark delete cross-checked
  against the browser profile's `Bookmarks` file (zero `UAT8` remnants). **UAT-8 = PASS.**

---

## 6. Records integrity (the two items the phase's own records flag)

| Check | Result |
|-------|--------|
| 11-VALIDATION.md claims 39 tasks | **39 rows** counted (`grep -c '^| 11-'`) — matches |
| Exactly two human-checks, `11-12-02` and `11-13-04` | Confirmed — only these two rows lack an `<automated>` command |
| Neither human-check adjacent to another | Confirmed — `11-12-02` is bracketed by `11-12-01`/`11-12-03`; `11-13-04` follows three automated tasks |
| Table actually contains `11-13-01`…`11-13-04` | All four present (lines 87-90), each with a decision ref, threat ref and command |
| Every one of the 13 plans has a SUMMARY | `11-01` … `11-13` — **13/13 present** |

---

## 7. Test evidence

| Suite | Result | Source |
|-------|--------|--------|
| `flutter test` | 609 green | orchestrator, at `58de289` |
| `flutter analyze` | clean | orchestrator, at `58de289` |
| `cargo test --workspace` | 202 | orchestrator |
| `remote_protocol` dart test | 13 | orchestrator |
| `cargo test --test extension_guard` | **4 passed** | **run by this verification** (see §2 for why) |
| `11-13-03` spec grep assertions | **0 / 2 — as specified** | **run by this verification** |
| On-device UAT | 11 PASS / 0 FAIL | `11-UAT.md`, original run + UAT-8 re-run |

---

## 8. Gaps

**None.** Every clause of the phase goal has code behind it, and every one of D-01…D-14 is delivered
by an identified artifact that was read, not inferred.

### Acknowledged deferrals (not gaps — recorded with rationale in `deferred-items.md`)

| # | Item | Standing |
|---|------|----------|
| 1 | Group-title cap could emit a lone surrogate | **CLOSED** 2026-07-31 by quick 260731-d45 — `capTitle(s, max)` at `background.js:48-52` now trims a trailing high surrogate and serves **both** title caps |
| 2 | Press-and-hold >100 ms on a tab-row star also fires the row's `tabs.activate` | Open by owner decision. Property of the row's **locked** tap-down activate; self-heals on the next push; a fix changes shipped press-down feel |
| 3 | Truncation copy reads as unintuitive (and is always on screen — 538 nodes vs a 500 cap) | Open by owner decision. UX/copy judgement; shipped behaviour matches 11-09's contract and every test. Raising the cap has protocol-budget consequences and needs its own plan |
| 4 | The 100 ms press flash is imperceptible on bookmark **link** rows | Open by owner decision. Verified **not** caused by 11-13 — the flash fires from `onTapDown` before and after the fix, byte-identical trigger point. Pre-existing perceptual issue; a duration change is a motion-budget change |

### Observation (non-blocking, bookkeeping only)

`.planning/ROADMAP.md` is uncommitted in the working tree. The diff is the plan-checkbox update only
(`11/13 → 13/13`, two `[ ] → [x]`). No source file is dirty; no bearing on goal achievement.

---

## Final verdict

**PASSED.** The phase goal is achieved in the codebase.

The phone can browse the tree by folder, open a bookmark in a new tab, star and unstar any tab, and
delete a bookmark or an empty folder — as a second segment on the existing Browser screen at
protoVersion 1.6, with URL resolution confined to the extension.

Three findings raise confidence above a routine pass:

1. **The no-url invariant is enforced structurally at three independent tiers**, not by convention.
   The server's serde drop means a compromised extension still cannot put a URL on the phone wire.
   That is the right shape for a security-adjacent rule.
2. **The one clause that failed on device is genuinely fixed**, and the fix landed with the assertion
   that was missing the first time — the old tests crossed the timing boundary but never checked that
   the wrong thing *didn't* happen. Fixing the test's semantics is what stops this recurring.
3. **The D-10 and D-14 prohibitions are test-enforced against extension source**, so the two rules
   with no runtime undo path cannot be quietly regressed.

_Verified: 2026-07-31 · Verifier: Claude (gsd-verifier) · Not committed — orchestrator bundles._
