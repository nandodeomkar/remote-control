# Phase 11 — On-device UAT results

Recording sheet for the eleven-step on-device UAT (plan `11-12`, task 2). Every row must carry a
non-empty **Observed** column before the phase can close — **an unrecorded outcome is a FAIL even
when nothing visibly broke**. Do not mark a row PASS without an observation written beside it.

## Verdict — 10 PASS / 1 FAIL. Phase 11 is NOT clear to close.

Run completed on real hardware 2026-07-30. All eleven rows carry an observation.

| Row | Result | One-line |
|-----|--------|----------|
| UAT-1 | PASS | A1 answered: permission-widening reload of an unpacked extension is granted **silently** (Comet 150). Required a Remove + Load-unpacked to get a valid pre-state. |
| UAT-2 | PASS | Roots render and drill correctly. Mobile bookmarks absent because Comet's `getTree()` withholds it — not a D-08 violation. |
| UAT-3 | PASS | 500 nodes / 37,845 B / 4.57 ms. **Truncation is live on the real collection** (538 nodes vs a 500 cap). No disconnects. |
| UAT-4 | PASS | Three opens from a nested folder; segment and folder position both held. |
| UAT-5 | PASS | Star filed into Bookmarks bar on a profile with **non-standard root ids** (`other=371`) — a real D-10 win. |
| UAT-6 | PASS | Both copies of a duplicated URL removed, behind the confirm. An earlier uncontrolled attempt anomaly did not reproduce (Anomaly A). |
| UAT-7 | PASS | Star fills instantly, no flicker when the push lands. |
| **UAT-8** | **FAIL** | **Long-press delete is unreachable on folders; on links it forces an unwanted open. See Failure B.** |
| UAT-9 | PASS | Both segments flip to the install hint; extension leg dropped while the phone leg stayed up. |
| UAT-10 | PASS | Paused input blocks the open but not the list — actuation gated, observation intact. |
| UAT-11 | PASS | Full regression clean; macro grid rect held across segment switches. |

**Blocking item:** Failure B (UAT-8). D-14's empty-folder delete cannot be invoked by any gesture, and reaching a link's delete forces the link to open. Needs its own plan; not fixable from inside 11-12.

**Non-blocking items raised:** deferred item 3 (truncation copy is accurate but unintuitive — now permanent on-screen state for this profile), and Anomaly A (unreproduced partial unstar; watch item, with a note that `bm.unstar`'s silent `.catch(() => {})` would hide a genuine intermittent failure).

**Profile left dirty by the run** (delete in the browser's bookmark manager; the folder cannot be removed from the phone because of Failure B): `Search by name` id 587 in Bookmarks bar (created by UAT-7), and the empty `UAT8 test folder` id 588 in Other bookmarks.

## Environment

| Field | Value |
|-------|-------|
| Date | 2026-07-30, ~22:30–23:00 IST |
| Browser | **Comet** (Perplexity Chromium fork), profile `Default` — NOT Chrome. See the A1 fidelity note below. |
| Browser version | **150.0.7871.115** (Official Build) (64-bit), Perplexity build number **230** |
| Server actually launched | **The repo exe** `server\target\release\server-windows.exe` (md5 `cb95d14f…`), PID 26940, started 22:34:40 IST. The stale installed `RemoteControl.exe` (md5 `ff9e92ec…`) **was** running at 22:34 from the Start-menu shortcut and was stopped first — the trap the note below warns about was live. Listening `0.0.0.0:17777` (phone) + `127.0.0.1:17779` (extension). |
| Phone link during run | `192.168.29.18` → `192.168.29.42:17777`, established for the whole run |
| Extension folder the browser loads from | `C:\Users\omkar\AppData\Local\Programs\RemoteControl\extension` (unpacked, `location=4`, id `ekmedhfioelkaaegoanhpeageahjaeng`) — placed by the v1.4.0-rc1 Inno installer, **byte-identical** to the repo's `extension/` |
| Server exe | `C:\Users\omkar\Projects\Remote Control\server\target\release\server-windows.exe` (v1.4.0, built 2026-07-30 09:22:45 +0530, md5 `cb95d14f18e8a7fa5c01053ff3de936d`) |
| APK | `C:\Users\omkar\Projects\Remote Control\app\remote_control\build\app\outputs\flutter-apk\app-release.apk` (1.4.0+7, built 2026-07-30 09:23:17 +0530) |
| Phone | Xiaomi 25080RABDI (`5dqwzpdqemsc6xpb`) — installed 2026-07-30 09:23:55, versionName 1.4.0 / versionCode 7 |

> **Launch the repo exe, not the installed one.** `C:\Users\omkar\AppData\Local\Programs\RemoteControl\RemoteControl.exe`
> is the 08:38 pre-relink build (md5 `ff9e92ece08bfa7f25abd39dbd6fccde`) — same byte size, different content
> from the 09:22 exe under test. `c4472da` was docs-only so they are near-certainly functionally identical
> (PE timestamp / build-id differ), but the Start-menu shortcut runs the wrong one. Record which was used.

> **Pre-UAT state, as found (verified 2026-07-30, orchestrator).** The gate-time scan looked only at
> Chrome, Brave and Edge and found nothing loaded. The extension is in fact loaded in **Comet**, whose
> profiles that scan did not cover. Corrected findings from `Comet\User Data\Default\Secure Preferences`:
>
> - Loaded unpacked from `C:\Users\omkar\AppData\Local\Programs\RemoteControl\extension`, manifest `1.2.0`
>   with `bookmarks` present. Byte-identical to the repo's `extension/` (manifest, `background.js`, README).
>   **Task 1's staging criterion is therefore already met** — the installer did it; nothing needed copying.
> - `granted_permissions.api` = `["alarms","bookmarks","tabs","favicon","tabGroups"]`, `disable_reasons: []`,
>   `withholding_permissions: false` → enabled, `bookmarks` already granted, nothing pending.
> - `first_install_time` == `last_update_time` == `2026-07-30T03:38:22Z` (09:08:22 IST). Identical
>   timestamps mean this was a **fresh Load-unpacked, never an update in place**.
>
> Timeline: 08:36 manifest built → 08:38 exe built → 09:00 installer ran → **09:08 Load-unpacked in Comet
> (bookmarks granted at initial load)** → 09:22 exe relinked → 09:23 APK built + installed.
>
> **Consequence for A1: pressing the reload arrow now cannot measure anything.** `bookmarks` is already in
> `granted_permissions`, so no approval prompt can appear regardless of Chromium's real update behaviour —
> it would read as outcome (a) and settle nothing. That is exactly the false pass the plan warns against.
> The pre-state must be recreated on the same path first; UAT-1 below carries that procedure.
>
> **Do not Load-unpacked the `Documents\RemoteControl-Extension-v1.2.0\extension\` copy.** Unpacked
> extension IDs derive from the absolute path, so a second folder registers a second Tab Bridge with its
> own ID and two extensions would push to the same server. That folder is used only as a source of `1.1.0`
> files (manifest `1.1.0`, no `bookmarks`, 0 bookmark-code references) to copy ONTO the existing path.
>
> **A1 fidelity.** Whatever is observed here is a **Comet** result. RESEARCH framed A1 as "current-stable
> Chrome" and its prediction of outcome (a) comes from an MV2-era doc page with no MV3 restatement — that
> prediction is not evidence. Task 3's README parenthetical must name Comet and its version, not imply Chrome.

## Results

| # | What was done | Observed | PASS / FAIL |
|---|---------------|----------|-------------|
| **UAT-1** | **A1 experiment — recreate the pre-state, then perform a real update.** All four steps act on the SAME path (`…\Programs\RemoteControl\extension`); never Load-unpacked a second folder. **(1)** Copy `manifest.json` + `background.js` from `C:\Users\omkar\Documents\RemoteControl-Extension-v1.2.0\extension\` (v`1.1.0`, no `bookmarks`) over that path. **(2)** Press the reload arrow in Comet's `chrome://extensions`; confirm the row now shows the narrower permission set (no bookmarks) and the phone's tab list still works — this is the pre-state, not the measurement. **(3)** Copy the repo's `C:\Users\omkar\Projects\Remote Control\extension\` (v`1.2.0`, `bookmarks`) back over that path. **(4)** Press the reload arrow. **That press is the measurement.** Record which happened: **(a)** the extension stays enabled and the phone's tab list keeps working, or **(b)** Comet shows a re-enable / permission-approval prompt and the extension is disabled until accepted. Either outcome PASSES; leaving it unrecorded FAILS. Also record what the phone's Browser screen showed during that window, and the Comet version. | **Outcome (a) — silent auto-grant, no prompt.** The documented procedure alone was NOT sufficient to recreate the pre-state; see "granted vs active" below. **Run as executed:** (1) v1.1.0 `manifest.json`+`background.js` copied over the installed path (md5-verified against the `Documents` source). (2) Reload arrow pressed → card read `1.1.0`, Details showed no bookmarks, phone tab list still worked, both legs stayed connected. **But `Secure Preferences` showed `active_permissions` had dropped `bookmarks` while `granted_permissions` RETAINED it** — Chromium keeps the historical approval record separately, and the re-upgrade prompt decision is made against `granted_permissions`. Pressing reload at that point would have measured nothing (the false pass the plan warns about). (3) Extension **Removed** in `chrome://extensions` and **Load-unpacked** again from the SAME path — verified exactly one unpacked extension, same id `ekmedhfioelkaaegoanhpeageahjaeng`, and `granted_permissions` = `alarms, tabs, favicon, tabGroups` with **no bookmarks** = a true never-approved pre-state. (4) Repo v1.2.0 copied over (md5-identical to `extension/`), reload arrow pressed. **Result: no prompt of any kind; card went straight to 1.2.0 and stayed enabled; `disable_reasons` stayed `[]`; phone tab list kept working uninterrupted; extension reconnected on a fresh ephemeral port.** Prefs after: both `granted_permissions` and `active_permissions` = `alarms, bookmarks, tabs, favicon, tabGroups`, `last_update_time` advanced. So a never-approved `bookmarks` was granted **silently**. | PASS |
| UAT-2 | Open the Bookmarks segment. Confirm all Chrome roots appear as folders (Bookmarks bar, Other bookmarks, Mobile bookmarks). Drill two levels down and back out. | **PASS with a documented deviation on the root list.** Bookmarks bar and Other bookmarks both rendered as folders; two-level drill-in and back-out worked. **Mobile bookmarks did NOT appear — and that is correct behaviour, not a D-08 violation.** Verified from both ends: the profile's `Bookmarks` file DOES contain a `synced` / "Mobile bookmarks" root (0 children), but `chrome.bookmarks.getTree()` in Comet returns only TWO roots — `[{id:"1", title:"Bookmarks bar", folderType:"bookmarks-bar", kids:25}, {id:"371", title:"Other bookmarks", folderType:"other", kids:0}]`. The extension cannot emit a root the API never hands it, and the frame's top level matched getTree exactly. Note the asymmetry that prompted the check: Other bookmarks is ALSO empty (0 children) and did render, so emptiness is not the filter — Comet simply withholds the synced root from the extensions API. **Incidental D-10 confirmation:** Other bookmarks carries id `"371"`, not the conventional `"2"` — real-world proof that the hardcoded-root-id prohibition in `bookmarksBarId()` is load-bearing, not theoretical. | PASS |
| UAT-3 | With the real bookmark collection loaded, read the service-worker console: record the node count and the frame byte size from the snapshot log line, and confirm **no** `[tab-bridge] disconnected` follows a snapshot. Time one `getTree()` pass with `console.time` (the A3 measurement). | **500 nodes / 37,845 bytes** read from `[tab-bridge] bm snapshot sent:` (`background.js:378`), reproduced across repeated passes; `getTree()` **4.57 ms**; `truncated: true` (538 API-visible nodes vs the 500-node cap, ~38 dropped). **No `[tab-bridge] disconnected` after any snapshot.** bm snapshot consistently logged BEFORE the tab snapshot (D-11 ordering as designed); paired tab line read `5 tabs, 0 groups, 5 star-known`. Full detail and findings in the A3 section below. | PASS |
| UAT-4 | From a nested folder, open three bookmarks in a row. Confirm three new tabs open, the phone is still on the Bookmarks segment, and still in the same folder. | Three bookmarks opened in a row from a nested folder: three new tabs opened, the phone stayed on the Bookmarks segment, and stayed inside the same folder — no bounce to the top level and no flip to Tabs. | PASS |
| UAT-5 | Star a tab, then check Chrome's own bookmark manager: confirm the new bookmark landed in the **Bookmarks bar**, not Other bookmarks. | Starred the "Search by name" tab (an RCI CRR portal page) from the phone. Verified against the profile's `Bookmarks` file rather than the manager UI: **Bookmarks bar went 25 → 26 children; Other bookmarks stayed 0; Mobile bookmarks stayed 0.** The newest node by `date_added` is `name="Search by name", type=url, id=583, parent=Bookmarks bar`. **This is a meaningful D-10 pass, not a trivial one** — on this profile the roots are numbered `bookmark_bar=1`, `other=371`, `synced=372`, so the conventional assumption that "2" is Other bookmarks is false here. `bookmarksBarId()`'s `folderType === "bookmarks-bar"` lookup resolved correctly against non-standard ids; a hardcoded-id or localized-title implementation would have been at real risk of misfiling on this exact profile. Also re-confirms UAT-2: Mobile bookmarks holds a real id (`372`) in the profile yet is still absent from `getTree()`. | PASS |
| UAT-6 | Bookmark one URL in two different folders, then unstar that tab from the phone. Confirm the confirm dialog appears and that after confirming **both** entries are gone in the bookmark manager. | **PASS on a controlled run.** Two-copy state verified by the orchestrator from the profile's `Bookmarks` file BEFORE the unstar: `583` in Bookmarks bar + `586` in Other bookmarks, 2 copies of "Search by name". Owner then unstarred from the phone: **confirm dialog appeared**, pressed Remove. Immediately after: Bookmarks bar 26 → **25**, Other bookmarks 1 → **0**, **0 copies remaining**. D-11 "remove every bookmark whose url exactly matches" holds, and the destructive path is confirm-gated as designed. **Anomaly on a first, uncontrolled attempt — did NOT reproduce, see Failures.** | PASS |
| UAT-7 | Tap a star and watch the row before the next push. Confirm it flips instantly and stays flipped after the push lands. | Tapped the star on the (now hollow) "Search by name" tab row. **Filled instantly on the tap**, with no perceptible delay, and **stayed filled with no flicker** as the subsequent `bm.state` / `tabs.state` push landed. The optimistic flip and the authoritative push agree — no fill → hollow → fill clobber. Matches the 11-11 contract that adding is optimistic and instant while only removal is confirm-gated. | PASS |
| UAT-8 | Try to delete a **non-empty** folder from the phone (no long-press affordance should be offered at all), then empty it and retry (the delete now works, behind the confirm). | **FAIL — the second half of this row is unreachable on device.** Setup: `UAT8 test folder` (id 588) containing `UAT8 child` (id 589) created under Other bookmarks. **Non-empty folder:** no delete offered — but NOT because the D-14 gate withheld it; the row cannot be long-pressed at all, because the first touch navigates into the folder. **Emptied folder (`count == 0`, so `isDeletable` is TRUE and `onLongPress` is genuinely wired):** long-press **still** just navigates in, no confirm dialog, delete never reachable. The empty-folder delete D-14 explicitly permits therefore cannot be invoked by any user gesture. **Second defect found in the same row:** long-pressing a LINK does work (confirm dialog appeared) but **also opens the bookmark in a PC tab** — deleting a bookmark forces you to open it first. See Failure B. | **FAIL** |
| UAT-9 | Close the browser entirely. Confirm **both** segments flip to the install hint — no stale bookmark tree sitting next to a correct hint. | Closed Comet entirely. **Both segments flipped to the install hint** — no stale bookmark tree left rendering beside a correct hint on the other segment. Verified server-side that the degradation had the right cause and the right blast radius: **zero Comet processes**, the extension leg on `127.0.0.1:17779` **dropped**, while the phone leg `192.168.29.18 → :17777` **stayed established**. So the hint reflects a dead browser bridge, not a lost phone connection — the two failure modes stay distinguishable, and the shared `InstallHintCard` (11-09, one widget across both segments, no fork) degrades them together. | PASS |
| UAT-10 | Pause input from the tray, then switch to Bookmarks. Confirm the list still loads (`bm.list` is a read) and that tapping a bookmark does nothing (executor-bound). | With input paused from the tray, switched to the Bookmarks segment: **the list still loaded** (the read path `bm.list` is correctly unaffected by pause), and **tapping a bookmark opened nothing** on the PC (the open path is executor-bound and correctly gated). Pause suppresses actuation without blinding observation, which is the intended split. | PASS |
| UAT-11 | Regression: tab activate, long-press close, swipe close, and all seven macro buttons behave exactly as before the phase. Confirm the macro grid does not move when switching segments. | All five checks pass: tab activate, long-press close, swipe close, and all seven macro buttons behave as before the phase; the pinned macro grid **did not move** across repeated Tabs ↔ Bookmarks segment switches (D-02's identical-rect guarantee confirmed on device, matching 11-10's `tester.getRect` equality tests). **Notable contrast with Failure B:** long-press close on a TAB row works correctly even though tab rows share the same tap-down-activate + long-press arena shape. The tab row survives its own tap-down action (activating a tab does not remove the row), so long-press still resolves — the same reason the bookmark LINK case works and only the FOLDER case dies. This narrows Failure B to rows whose tap-down action destroys or replaces the row. | PASS |

## A1 outcome (drives the `extension/README.md` wording in task 3)

Observed on real hardware 2026-07-30. **Outcome (a): a permission-widening reload of an UNPACKED extension is granted silently.**

| Field | Value |
|-------|-------|
| Browser measured | **Comet 150.0.7871.115** (Official Build) (64-bit), Perplexity build 230 |
| Outcome | **(a) stayed enabled.** No prompt, no dialog, no banner, no disabled state — there was no prompt text to record verbatim because none appeared. Card moved `1.1.0` → `1.2.0` and remained enabled. |
| Phone Browser screen during the window | Tab list kept working throughout — stayed populated with the Comet tabs, no install hint, no visible interruption. Both sockets stayed established; only the extension's ephemeral source port changed as the service worker restarted. |
| Pref-level confirmation | `granted_permissions` went `alarms, tabs, favicon, tabGroups` → `alarms, bookmarks, tabs, favicon, tabGroups`; `disable_reasons` `[]` throughout; `last_update_time` advanced. |

### Scope limits on this result — task 3 must not overstate it

1. **This is Comet 150, not Chrome.** RESEARCH framed A1 as "current-stable Chrome" and predicted (a) from an MV2-era doc page with no MV3 restatement. That prediction is now *consistent with* an observation, but the observation is on a Perplexity Chromium fork. The README parenthetical must name Comet and its version, not imply Chrome.
2. **This is the UNPACKED / reload-arrow path only** — which is the Tab Bridge's actual distribution path, so it is the relevant case. It is NOT evidence about Web Store updates, where Chromium's documented behavior for a permission increase is to disable pending re-approval. Do not generalize.
3. **`granted_permissions` vs `active_permissions` is the load-bearing detail** (discovered during this run, not anticipated by the plan). A downgrade-then-reload does NOT clear the historical grant, so the naive four-step procedure in UAT-1 measures nothing on a profile that ever had 1.2.0 loaded. Recreating the pre-state requires a full **Remove + Load unpacked**. Anyone re-running A1 must do that or they will record a false pass.

## A3 measurement

Measured 2026-07-30 in the Tab Bridge service-worker console against the owner's real collection.

**Method.** The node count and frame size were read from the snapshot log line exactly as the sheet specifies — `background.js:378` emits `[tab-bridge] bm snapshot sent: <count> nodes, <bytes> bytes` on every successful `bm.state` send (counts and lifecycle only, never a title or url). Observed live and repeatedly:

```
[tab-bridge] bm snapshot sent: 500 nodes, 37845 bytes
background.js:517 [tab-bridge] snapshot sent: 5 tabs, 0 groups, 5 star-known
```

The `truncated` flag and the `getTree()` timing are not in that line, so those two were measured separately by calling the shipped functions from the service-worker console — read-only, sends no frame:

```javascript
console.time('getTree'); const s = await buildBmSnapshot(); console.timeEnd('getTree');
console.log('nodes:', s.count, 'bytes:', bytesOf(s.frame), 'truncated:', /"truncated":true/.test(s.frame));
```

Both paths returned identical counts (500 nodes / 37,845 bytes), so the console measurement and the production log line corroborate each other.

**Ordering confirmed as designed.** Every pass logged the bm snapshot BEFORE the tab snapshot, which is the documented D-11 requirement — `buildAndSendAll()` rebuilds `bmUrlSet` first so the tab snapshot that follows reads fresh star truth. The paired `5 tabs, 0 groups, 5 star-known` line shows all five open tabs carried a resolved `bookmarked` flag (0 star-known would have meant an unreadable tree).

**No disconnect after a snapshot.** No `[tab-bridge] disconnected` line appeared after any snapshot across repeated passes — the 37,845 B frame sits well inside the server's cap and the extension leg stayed up for the whole run.

| Metric | Value |
|--------|-------|
| Bookmark node count (emitted) | **500** — `MAX_BM_NODES` cap hit exactly |
| Bookmark node count (available) | **538** API-visible (26 folders + 513 links, max depth 4, counted from the profile's `Bookmarks` file; excludes the `synced` root that `getTree()` withholds) |
| Nodes dropped by truncation | **~38** |
| `truncated` flag | **true** |
| Serialized frame size (UTF-8 bytes) | **37,845** — comfortably under `MAX_FRAME_BYTES` 57,344 |
| `getTree()` timing | **4.57 ms** |

**Findings.**

1. **The truncation path is LIVE on the owner's real collection**, not a theoretical edge — 538 nodes against a 500-node cap. This is the opposite of the orchestrator's initial read (it mistook the bookmarks bar's 25 top-level children for the tree total). The honest-truncation copy shipped in 11-09 is therefore production behaviour for this profile, not dormant code.
2. **`MAX_BM_NODES` is the binding constraint, not `MAX_FRAME_BYTES`.** At 500 nodes / 37,845 B the average node costs ~75.7 B, so the 57,344 B budget would not bite until ~758 nodes — which the 500-node cap makes unreachable. The byte-trim `while` loop in `buildBmSnapshot` never executes at this title length; only the node cap ever fires. Any future raise of `MAX_BM_NODES` above ~750 would newly activate that loop.
3. `getTree()` at 4.57 ms is far below any plausible frame-budget concern; A3 raised no performance issue.
4. **Truncation copy verified on device and logged as a UX problem.** Because the cap genuinely bites here, the `kBmTruncatedSnapshot` line ("Showing the first 500 bookmarks.") is permanently on screen for this profile. The owner confirmed it renders and is accurate, but judged the presentation unintuitive. Functionally correct, so not a UAT failure — raised as **deferred item 3** rather than fixed inside plan 11-12 (docs + UAT scope only). Any redesign should consider the cap itself alongside the wording, given finding 2.

## Failures

### Anomaly A — UAT-6 first attempt: unstar appeared to leave one copy. NOT REPRODUCED.

**What was observed.** On a first, uncontrolled attempt at UAT-6 the owner pasted a duplicate into Other bookmarks and unstarred from the phone in one go, then reported "bookmark only deleted from other bookmarks. Tab still appears as starred as it is bookmarked in bookmarks bar." Orchestrator's post-hoc read of the profile: Bookmarks bar **26** children with `583` still present, Other bookmarks **0**, star still lit on the phone.

**Why it is not recorded as a defect.** The starting state was never verified — the check ran only *after* the unstar, so "both copies existed and one survived" and "the paste never landed and nothing was removed" produce an identical post-state. Both are consistent with the evidence and they have opposite causes.

**Diagnostics run at that moment (service-worker console), all of which ARGUE AGAINST a removal bug:**

- `583` was modifiable — `unmodifiable: undefined`, so the handler's `if (node.unmodifiable) continue` skip never applied.
- `chrome.bookmarks.search({url: b.url})` **did** return `583` — so `search` is not failing to find it.
- The live tab's URL matched `583`'s **exactly** (63 chars, exact-equality confirmed, and equal again under a trailing-slash/hash-insensitive comparison) — so `bmUrlSet` star truth was correct and there was no near-miss URL.

In other words every precondition for `bm.unstar` to remove `583` was satisfied at inspection time, which is incompatible with a deterministic bug in the remove path.

**Controlled re-run passed cleanly.** With the two-copy state (`583` Bookmarks bar + `586` Other bookmarks) verified on disk beforehand, a single phone unstar removed BOTH (26 → 25 and 1 → 0, zero copies left). See UAT-6.

**Residual, honestly stated.** The first attempt's cause is unproven. The most plausible benign explanation is that the paste had not committed when the unstar fired, leaving one copy and a `chrome.tabs.get(p.tabId)` that rejected on a stale phone-side tabId — both silently swallowed by the handler's `.catch(() => {})`, which is deliberate (a managed node or a concurrently-deleted node must not abort the remaining removals). That same silence means a genuine intermittent failure would also leave no trace. **Watch item, not a fix:** if a partial unstar is ever seen again, the first change should be to log the swallowed rejections in `bm.unstar` — the current code cannot distinguish "nothing to remove" from "every removal failed". Not actioned here: plan 11-12 is docs + UAT scope and the sheet forbids patching source from inside it.

### Failure B — UAT-8: long-press delete is unreachable on folders, and forces an unwanted open on links. REPRODUCIBLE.

**Severity: real functional gap.** A documented, deliberately-designed capability (D-14's "an EMPTY folder may be deleted, behind a confirm") cannot be invoked by any gesture on device. This is not a gate working as intended — the gate is open and the affordance is still unreachable.

**Observed, on device.**

| Case | `isDeletable` | Long-press outcome |
|------|---------------|--------------------|
| Non-empty folder (`UAT8 test folder`, count 1) | false (correctly gated) | Navigates into the folder on first touch. No dialog — but the gate was never the reason. |
| **Empty folder** (same folder, count 0) | **true — `onLongPress` IS wired** | **Still navigates in. No dialog. Delete unreachable.** |
| Link (`UAT8 child`) | true | Confirm dialog DOES appear — **but the bookmark also opens in a PC tab.** |

**Cause, from source.** `_BmRow` puts all three gestures on one `InkWell` (`app/remote_control/lib/browser/bookmarks_section.dart:315-319`):

```dart
onTap: widget.enabled ? () {} : null,
onTapDown: widget.enabled ? (_) => _fire() : null,
onLongPress: deletable ? _confirmDelete : null,
```

`_fire()` calls `onEnterFolder` for a folder and `onOpen` for a link. Flutter's `BaseTapGestureRecognizer` invokes `handleTapDown` at the ~100 ms press deadline (`kPressTimeout`) rather than only on winning the arena, while `LongPressGestureRecognizer` does not fire until ~500 ms. Every long press therefore executes the tap-down action first:

- **Folder** — navigation swaps the list at 100 ms, so the pressed row is gone before long-press can resolve. The delete is unreachable *by construction*, for every folder, empty or not.
- **Link** — the row survives the open, so long-press still lands at 500 ms; the open is an unavoidable side effect of reaching the delete.

**Relationship to deferred item 2.** Same root cause (tap-down activate coexisting with long-press) but a materially worse consequence. Item 2's blast radius is a benign, self-healing tab switch. Here an entire designed capability is inert, and the reachable half of it has a destructive-adjacent side effect (opening a tab the user did not ask for while trying to delete). Item 2 was correctly deferred; this should not be folded into it.

**Why the automated suite did not catch it.** Widget tests drive `onLongPress` directly, so they prove `_confirmDelete` → `onDelete` is correct — which it is. They never model the arena race between a 100 ms tap-down and a 500 ms long-press on the same recognizer set, so the handler is verified while the path to it is not. Any fix should add a test that pumps a real timed press (`tester.press` + `pump(600ms)`) and asserts the folder did NOT navigate.

**Not fixed here.** Plan 11-12 is docs + UAT scope and this sheet forbids patching source from inside it. Fix directions (none chosen): move row activation from `onTapDown` to `onTap` (changes the shipped press-down feel that 11-10/11-11 deliberately preserved), or give the row an explicit trailing affordance for delete instead of relying on long-press. **This needs its own plan and should be resolved before the phase is called complete.**

### Other failures

_(UAT-1 through UAT-7 all PASS; UAT-8 FAIL as above. Record any further failure verbatim; do not patch source from inside plan 11-12)_
