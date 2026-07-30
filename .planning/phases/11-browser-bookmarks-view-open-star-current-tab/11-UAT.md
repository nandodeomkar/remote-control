# Phase 11 — On-device UAT results

Recording sheet for the eleven-step on-device UAT (plan `11-12`, task 2). Every row must carry a
non-empty **Observed** column before the phase can close — **an unrecorded outcome is a FAIL even
when nothing visibly broke**. Do not mark a row PASS without an observation written beside it.

## Environment

| Field | Value |
|-------|-------|
| Date | _(not yet run)_ |
| Browser | **Comet** (Perplexity Chromium fork), profile `Default` — NOT Chrome. See the A1 fidelity note below. |
| Browser version | _(record from `chrome://version` in Comet)_ |
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
| **UAT-1** | **A1 experiment — recreate the pre-state, then perform a real update.** All four steps act on the SAME path (`…\Programs\RemoteControl\extension`); never Load-unpacked a second folder. **(1)** Copy `manifest.json` + `background.js` from `C:\Users\omkar\Documents\RemoteControl-Extension-v1.2.0\extension\` (v`1.1.0`, no `bookmarks`) over that path. **(2)** Press the reload arrow in Comet's `chrome://extensions`; confirm the row now shows the narrower permission set (no bookmarks) and the phone's tab list still works — this is the pre-state, not the measurement. **(3)** Copy the repo's `C:\Users\omkar\Projects\Remote Control\extension\` (v`1.2.0`, `bookmarks`) back over that path. **(4)** Press the reload arrow. **That press is the measurement.** Record which happened: **(a)** the extension stays enabled and the phone's tab list keeps working, or **(b)** Comet shows a re-enable / permission-approval prompt and the extension is disabled until accepted. Either outcome PASSES; leaving it unrecorded FAILS. Also record what the phone's Browser screen showed during that window, and the Comet version. | | |
| UAT-2 | Open the Bookmarks segment. Confirm all Chrome roots appear as folders (Bookmarks bar, Other bookmarks, Mobile bookmarks). Drill two levels down and back out. | | |
| UAT-3 | With the real bookmark collection loaded, read the service-worker console: record the node count and the frame byte size from the snapshot log line, and confirm **no** `[tab-bridge] disconnected` follows a snapshot. Time one `getTree()` pass with `console.time` (the A3 measurement). | | |
| UAT-4 | From a nested folder, open three bookmarks in a row. Confirm three new tabs open, the phone is still on the Bookmarks segment, and still in the same folder. | | |
| UAT-5 | Star a tab, then check Chrome's own bookmark manager: confirm the new bookmark landed in the **Bookmarks bar**, not Other bookmarks. | | |
| UAT-6 | Bookmark one URL in two different folders, then unstar that tab from the phone. Confirm the confirm dialog appears and that after confirming **both** entries are gone in the bookmark manager. | | |
| UAT-7 | Tap a star and watch the row before the next push. Confirm it flips instantly and stays flipped after the push lands. | | |
| UAT-8 | Try to delete a **non-empty** folder from the phone (no long-press affordance should be offered at all), then empty it and retry (the delete now works, behind the confirm). | | |
| UAT-9 | Close the browser entirely. Confirm **both** segments flip to the install hint — no stale bookmark tree sitting next to a correct hint. | | |
| UAT-10 | Pause input from the tray, then switch to Bookmarks. Confirm the list still loads (`bm.list` is a read) and that tapping a bookmark does nothing (executor-bound). | | |
| UAT-11 | Regression: tab activate, long-press close, swipe close, and all seven macro buttons behave exactly as before the phase. Confirm the macro grid does not move when switching segments. | | |

## A1 outcome (drives the `extension/README.md` wording in task 3)

_(not yet observed — leave blank until UAT-1 step 4 has run on real hardware)_

| Field | Value |
|-------|-------|
| Browser measured | Comet (record exact version) |
| Outcome | _(a) stayed enabled / (b) re-approval prompt — record verbatim_ |
| Phone Browser screen during the window | _(record)_ |

## A3 measurement

| Metric | Value |
|--------|-------|
| Bookmark node count | _(not yet measured)_ |
| Serialized frame size (UTF-8 bytes) | _(not yet measured)_ |
| `getTree()` timing | _(not yet measured)_ |

## Failures

_(record any failure verbatim; do not patch source from inside plan 11-12)_
