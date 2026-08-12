---
phase: 11-browser-bookmarks-view-open-star-current-tab
plan: 12
subsystem: docs
tags: [uat, on-device, extension, chromium, permissions, bookmarks, release-artifacts]

# Dependency graph
requires:
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-04)
    provides: "the server-side bm.* relay and pre-auth gate the UAT exercises end to end"
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-06)
    provides: "buildBmSnapshot / bytesOf / MAX_BM_NODES in extension/background.js — the functions the README smoke check calls"
  - phase: 11-browser-bookmarks-view-open-star-current-tab (11-11)
    provides: "the tab-row star, the last feature surface the UAT had to cover"
provides:
  - "11-UAT.md — eleven recorded on-device rows, 10 PASS / 1 FAIL, with A1 settled and A3 measured"
  - "A1 answered by observation: a permission-widening reload of an UNPACKED extension is granted silently (Comet 150.0.7871.115)"
  - "A3 measured: 500 nodes / 37,845 B / getTree() 4.57 ms on the owner's real collection, truncation LIVE"
  - "extension/README.md — bookmarks capability, a Permissions table justifying `bookmarks`, an Updating section written from the observed outcome, and a privacy-clean bookmark snapshot check"
  - "Failure B (UAT-8) — the blocking defect that plan 11-13 exists to fix"
affects: [11-13, extension, docs, phase-close]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Write user-facing behaviour docs from a measurement, and name the browser and version in the doc so a future reader can judge how far the claim travels"
    - "Console-paste smoke checks that print counts and byte sizes only — never a title, never a URL — matching the shipped log line's privacy discipline"

key-files:
  created:
    - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-UAT.md
  modified:
    - extension/README.md
    - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md

key-decisions:
  - "The README states the silent-grant result but scopes it explicitly to Comet 150.0.7871.115 and to the unpacked / reload-arrow path — RESEARCH's Chrome-framed prediction is NOT restated as if it had been verified"
  - "A downgrade-then-reload does not recreate an A1 pre-state: Chromium keeps `granted_permissions` separate from `active_permissions`, so only a full Remove + Load-unpacked yields a never-approved profile"
  - "UAT-8's Failure B was recorded and left unpatched — plan 11-12 is docs + UAT scope, and the sheet forbids patching source from inside it"

requirements-completed: []

# Metrics
duration: ~3h (across three sessions: gate + artifacts, on-device UAT, README)
completed: 2026-07-31
---

# Phase 11 Plan 12: On-device UAT and the extension README Summary

**Eleven UAT steps run on the owner's real hardware — 10 PASS / 1 FAIL — settling A1 by observation (a permission-widening reload of an unpacked extension is granted silently on Comet 150), measuring A3 (500 nodes / 37,845 B / 4.57 ms, with truncation live on the real collection), and turning that A1 observation into the extension README's Updating section.**

## Performance

- **Duration:** ~3h across three sessions
- **Completed:** 2026-07-31
- **Tasks:** 3
- **Files created:** 1 (`11-UAT.md`)
- **Files modified:** 2 (`extension/README.md`, `deferred-items.md`)

## Task Commits

1. **Task 1: Full suite gate and fresh release artifacts** — `a2bed34` (docs; the task made no source changes, so the commit carries the gate record and the UAT recording sheet)
2. **Task 1 follow-up: correct the UAT sheet — the extension loads in Comet, not Chrome; add the A1 pre-state procedure** — `85dd8e5` (docs)
3. **Task 2: On-device UAT, eleven rows recorded** — `cd96781` (docs)
4. **Task 3: Write the extension README from the observed UAT-1 outcome** — `333c820` (docs)

## Accomplishments

### Task 1 — gate and artifacts (already complete before this session)

All four gates green and both release artifacts built explicitly:

- `cargo test --workspace` — **202 passing**
- `dart test` (`remote_protocol`) — **13 passing**
- `flutter test` — **601 passing**
- `flutter analyze` — **No issues found**
- `cargo build --release` → `server-windows.exe` v1.4.0, built 2026-07-30 09:22:45 +0530
- `flutter build apk --release` → `app-release.apk` 1.4.0+7, built 09:23:17, installed on the phone 09:23:55

The explicit `flutter build apk --release` before `flutter install` is the burned 08-06 lesson applied — `flutter install` reuses the last-built APK and would otherwise have put a stale binary on the phone with a fresh install timestamp.

The staging step (task 1 step 8) turned out to be already satisfied: the v1.4.0-rc1 Inno installer had placed a byte-identical `extension/` at `…\Programs\RemoteControl\extension`, and that is the folder the browser actually loads from. `85dd8e5` corrected the sheet for this and for the browser identity (see Deviations).

### Task 2 — the on-device UAT (already complete before this session)

Eleven rows, every one with a non-empty Observed column. **10 PASS / 1 FAIL.** Highlights:

- **UAT-1 settles A1 by measurement.** Outcome (a): the extension stayed enabled through a v1.1.0 → v1.2.0 reload that adds `bookmarks`. No prompt, no banner, no disabled card; `granted_permissions` silently gained `bookmarks` and `disable_reasons` stayed `[]`.
- **UAT-3 measures A3 and found truncation is live**, not theoretical: 500 emitted nodes against 538 API-visible, 37,845 B frame (vs the 57,344 B cap), `getTree()` 4.57 ms, no `[tab-bridge] disconnected` after any snapshot. `MAX_BM_NODES`, not `MAX_FRAME_BYTES`, is the binding constraint — the byte-trim loop never runs at this title length.
- **UAT-2 / UAT-5 gave D-10 a real-world win.** The owner's profile numbers its roots `bookmark_bar=1`, `other=371`, `synced=372`. A hardcoded-id implementation would have misfiled every star on this exact profile; `bookmarksBarId()`'s `folderType` lookup resolved correctly. UAT-2's missing "Mobile bookmarks" was traced to Comet withholding the `synced` root from `getTree()` — the extension cannot emit a root the API never hands it, so it is not a D-08 violation.
- **UAT-8 FAILED** — see Failures below.

### Task 3 — the extension README (this session's work)

`extension/README.md`, four changes, no existing install step touched:

1. **Intro and privacy framing now name bookmarks.** The extension feeds the open tab list *and* the bookmark tree to the server on this PC and executes tab and bookmark commands; the localhost-only framing is kept and extended — tab titles, favicons, and bookmark titles and ids go to the owner's own server, full URLs of tabs and bookmarks alike never leave the machine. That claim is exact: `buildBmSnapshot` emits `id`/`parentId`/`title`/`folder`/`count`/`locked` and collects URLs into a module-local `Set` that never reaches a frame.
2. **A Permissions table** covering all five manifest permissions, with `bookmarks` justified in the owner's terms: show the tree on the phone, file a starred tab into the bookmarks bar, remove a bookmark on unstar — titles and ids only, never a URL (T-11-12).
3. **An "Updating the extension" section written from the observed UAT-1 outcome.** Copy the new `extension` folder over the same path (with the reason: an unpacked extension's id derives from its absolute path, so a second copy registers a duplicate Tab Bridge), press the reload arrow, done — the extension **stays enabled** across the reload even when the update adds a permission. The parenthetical records that this was measured on real hardware 2026-07-30 on **Comet 150.0.7871.115** (Perplexity's Chromium fork, *not* Chrome), and states the two scope limits explicitly: it is evidence about the unpacked / reload-arrow path only, and web-store updates are documented to handle a permission increase differently.
4. **A bookmark snapshot check** in the developer section, shaped like the existing console-paste checks: `buildBmSnapshot().then(s => console.log('nodes:', s.count, 'bytes:', bytesOf(s.frame)))`, expected at or under 500 nodes and under 57,344 bytes. Read-only — it builds a frame and measures it, sends nothing — and it prints counts and sizes ONLY, no title and no URL, matching the shipped `[tab-bridge] bm snapshot sent:` line (T-11-02).

## Decisions Made

- **The README names Comet and its version rather than saying "Chrome".** RESEARCH framed A1 as a Chrome question and predicted outcome (a) from an MV2-era doc page with no MV3 restatement. The observation is now consistent with that prediction, but it is one observation on one Chromium fork. Writing "Chrome does X" would have laundered a prediction into a verified claim about a browser that was never tested.
- **The result is scoped to the unpacked / reload-arrow path in the doc itself.** That path is how the Tab Bridge is actually distributed, so it is the case the owner will hit — but the README says so out loud so a future reader does not carry the claim to a web-store listing, where Chromium's documented behaviour for a permission increase is the opposite.
- **The smoke check prints two numbers and nothing else.** The natural instinct is to also print the `truncated` flag or the largest node; both were rejected. The acceptance criterion is a count and a byte size, and every extra field is a new chance for a title to reach a screen at the PC.
- **Failure B was recorded, diagnosed from source, and left unfixed.** The sheet forbids patching source from inside plan 11-12, and the fix has a real design choice inside it (move row activation off `onTapDown`, changing shipped press-down feel, vs. add an explicit delete affordance). That decision belongs to its own plan — 11-13.

## Failures and open items

### UAT-8 / Failure B — BLOCKING, fixed by plan 11-13

D-14's empty-folder delete **cannot be invoked by any gesture on device**. `_BmRow` puts `onTapDown` (activate) and `onLongPress` (delete) on one `InkWell`; Flutter's `BaseTapGestureRecognizer` fires `handleTapDown` at the ~100 ms press deadline while `LongPressGestureRecognizer` waits ~500 ms, so every long press executes the tap-down action first. For a folder the list swaps at 100 ms and the pressed row is gone before long-press resolves — unreachable by construction, empty or not. For a link the row survives, so the confirm does appear, but the bookmark **also opens in a PC tab**: deleting forces an unwanted open.

The gate is not the problem — `isDeletable` is correctly `true` on the empty folder and `onLongPress` is genuinely wired. The widget suite drives `onLongPress` directly, so it proves the handler and never models the arena race. **Plan 11-13 exists to fix this. Phase 11 is NOT clear to close on 11-12 alone.**

### Anomaly A — watch item, not a defect

A first, uncontrolled UAT-6 attempt looked like a partial unstar. The starting state was never verified, so "one copy survived" and "the paste never landed" produce an identical post-state; every diagnostic run at that moment (node modifiable, `search({url})` finds it, exact URL match) argues against a deterministic bug, and the controlled re-run removed both copies cleanly. Recorded honestly with the note that `bm.unstar`'s deliberate `.catch(() => {})` would hide a genuine intermittent failure — if it is ever seen again, log the swallowed rejections first.

### Deferred item 3 — truncation copy

Logged to `deferred-items.md` during task 2. The truncation line is accurate and the mechanism works, but it is now permanent on-screen state for this profile (538 nodes vs a 500 cap) and the owner judged the presentation unintuitive. UX judgement, not a defect; any redesign should weigh the cap itself alongside the wording given that the frame had 19.5 KB of headroom.

## Deviations from Plan

### Task-1-level corrections (commit `85dd8e5`, made before this session)

**1. [Rule 1 - Bug] The gate-time browser scan looked at the wrong browsers**

- **Found during:** pre-UAT verification
- **Issue:** The scan covered Chrome, Brave and Edge and found nothing loaded. The extension is in fact loaded in **Comet**, whose profiles the scan never read. The plan's prose (and RESEARCH's A1 framing) assumed Chrome throughout.
- **Fix:** corrected `11-UAT.md`'s Environment block to the real browser and version, added the A1 fidelity note requiring task 3 to name Comet, and recorded that task 1's staging criterion was already met by the installer (the loaded folder is byte-identical to the repo's `extension/`).

**2. [Rule 1 - Bug] The plan's UAT-1 procedure could not measure anything**

- **Found during:** pre-UAT verification, then confirmed live during the run
- **Issue:** The profile already had `bookmarks` in `granted_permissions` from a fresh Load-unpacked at 09:08. Pressing the reload arrow would have read as outcome (a) and settled nothing — exactly the false pass the plan warns against. During the run it emerged that even the added downgrade-then-reload procedure is insufficient: reloading v1.1.0 clears `active_permissions` but **not** `granted_permissions`, and re-approval is decided against the latter.
- **Fix:** the sheet gained an explicit four-step pre-state procedure, and the run added a full **Remove + Load-unpacked** (same path, same extension id, verified exactly one unpacked Tab Bridge) to reach a genuinely never-approved state before the measuring reload.

### Task 3

None — the task was executed exactly as written, against the branch the UAT actually recorded.

## Verification

Plan task 3's acceptance criteria, run verbatim:

| Criterion | Result |
|-----------|--------|
| `node -e "…"` README/UAT check | prints `readme ok`, exit 0 |
| `grep -ci "bookmarks" extension/README.md` >= 3 | **4** |
| `grep -n "reload"` inside an "Updating" section | line 50, `## Updating the extension` |
| `grep -c "disabled until"` + `grep -c "stays enabled"` == 1 | **0 + 1 = 1** — only the observed branch is present |
| No `title` occurrence inside the new snippet | occurrences at lines 12, 39, 79, 97 — all pre-existing or prose; none in the snippet |
| `git diff extension/README.md` touches no install step | confirmed: diff is +62 / -5, no `Load unpacked` / `Developer mode` / download line touched |

Additional: the snippet parses under `node --check`, and `flutter analyze` re-run after the edit reports **No issues found** (90.8s).

## Threat Model Coverage

| Threat ID | Disposition | How it was met |
|-----------|-------------|----------------|
| T-11-02 | mitigated | The README smoke check prints `nodes:` and `bytes:` only; no title, no URL, no per-node field |
| T-11-07 | mitigated | UAT-3 measured the real collection: 37,845 B against the 57,344 B cap, no disconnect after any snapshot |
| T-11-01 | mitigated | UAT-10 (paused input: list loads, open does nothing) and UAT-9 (browser closed: both segments show the hint, no stale tree) |
| T-11-04 | partially met | UAT-8 confirmed a non-empty folder offers no delete — but the empty-folder delete is unreachable too (Failure B), so the *gate* is proven while the *capability* is inert. 11-13 closes this |
| T-11-12 | mitigated | The README's Permissions table states what `bookmarks` is for and that no URL is ever sent |
| T-11-SC | mitigated | No packages installed; builds used the already-pinned toolchains |

## Phase status

**Phase 11 is not closeable on this plan.** 11-12's own success criteria are met — artifacts built explicitly, eleven steps recorded on real hardware, A1 settled and A3 measured, README written from the observation — but UAT-8 returned a FAIL and plan **11-13** is the fix. The phase closes when 11-13 lands and UAT-8 re-runs clean.

**Profile left dirty by the UAT run** (must be cleaned from the browser's own bookmark manager — the folder cannot be removed from the phone because of Failure B): `Search by name` id 587 in Bookmarks bar, and the empty `UAT8 test folder` id 588 in Other bookmarks.

## Self-Check: PASSED

- `extension/README.md` — FOUND (modified, 4 sections changed)
- `.planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-UAT.md` — FOUND (eleven rows, all with observations)
- `.planning/phases/11-browser-bookmarks-view-open-star-current-tab/11-12-SUMMARY.md` — FOUND
- Commit `a2bed34` — FOUND
- Commit `85dd8e5` — FOUND
- Commit `cd96781` — FOUND
- Commit `333c820` — FOUND
