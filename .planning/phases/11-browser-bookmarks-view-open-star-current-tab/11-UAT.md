# Phase 11 — On-device UAT results

Recording sheet for the eleven-step on-device UAT (plan `11-12`, task 2). Every row must carry a
non-empty **Observed** column before the phase can close — **an unrecorded outcome is a FAIL even
when nothing visibly broke**. Do not mark a row PASS without an observation written beside it.

## Environment

| Field | Value |
|-------|-------|
| Date | _(not yet run)_ |
| Chrome version | _(record from `chrome://version`)_ |
| Server exe | `C:\Users\omkar\Projects\Remote Control\server\target\release\server-windows.exe` (v1.4.0, built 2026-07-30 09:22:45 +0530) |
| APK | `C:\Users\omkar\Projects\Remote Control\app\remote_control\build\app\outputs\flutter-apk\app-release.apk` (1.4.0+7, built 2026-07-30 09:23:17 +0530) |
| Phone | Xiaomi 25080RABDI (`5dqwzpdqemsc6xpb`) — installed 2026-07-30 09:23:55, versionName 1.4.0 / versionCode 7 |
| Extension folder Chrome loads from | _(record the actual path used — see the note below)_ |

> **Pre-UAT owner action.** At gate time no Tab Bridge extension was loaded in any Chromium
> browser on this PC (verified against every Chrome/Brave profile's `Preferences` and
> `Secure Preferences`; Chrome was not running, so the on-disk prefs were authoritative). The only
> copy on disk was a stale extraction at
> `C:\Users\omkar\Documents\RemoteControl-Extension-v1.2.0\extension\` carrying manifest `1.1.0`
> **without** the `bookmarks` permission. The executor deliberately did not overwrite it, because
> UAT-1 measures the *update* path and needs the pre-update state intact. See the UAT-1 row for the
> sequence that keeps A1 answerable.

## Results

| # | What was done | Observed | PASS / FAIL |
|---|---------------|----------|-------------|
| **UAT-1** | Load the pre-update folder (manifest `1.1.0`, no `bookmarks`) via `chrome://extensions` → Load unpacked, confirm the phone's tab list works, then replace the folder's contents with the repo's `extension/` (manifest `1.2.0`, `bookmarks` present) and press the **reload arrow** on the Tab Bridge row. Record which happened: **(a)** the extension stays enabled and the phone's tab list keeps working, or **(b)** Chrome shows a re-enable / permission-approval prompt and the extension is disabled until accepted. Also record what the phone's Browser screen showed during that window. | | |
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

_(not yet observed — leave blank until UAT-1 has run on real hardware)_

## A3 measurement

| Metric | Value |
|--------|-------|
| Bookmark node count | _(not yet measured)_ |
| Serialized frame size (UTF-8 bytes) | _(not yet measured)_ |
| `getTree()` timing | _(not yet measured)_ |

## Failures

_(record any failure verbatim; do not patch source from inside plan 11-12)_
