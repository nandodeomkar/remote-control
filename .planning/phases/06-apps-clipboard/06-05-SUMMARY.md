---
phase: 06-apps-clipboard
plan: 05
subsystem: ui
tags: [flutter, riverpod, clipboard, shared_preferences, websocket, protocol]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    plan: 04
    provides: "server clip.set/clip.get/clip.changed seam (arboard-backed WinClipboard, sensitive/16 KiB/echo skip)"
  - phase: 06-apps-clipboard
    plan: 03
    provides: "ConnectionService AppsSnapshot park pattern, media/apps screen scaffold, kHubTiles registry, PrefsKv seam"
provides:
  - "ConnectionService value-equal ClipSnapshot (clip.changed) + distinct clipFetchReply slot (clip.get reply); _onFrame ClipChangedMsg/ClipSetMsg arms"
  - "HistoryStore (PrefsKv key clip.history): last-5, move-to-head dedupe, persist, corruption-tolerant (D-06)"
  - "ClipNotifier send/fetch/reuse; clipTextTooLarge UTF-8 byte hard cap (T-06-16b); identity-tracked ClipFetchEvent"
  - "ClipboardScreen (Send/Fetch + Recent history) per 06-UI-SPEC; Clipboard hub tile after Apps"
affects: [06-06 auto-sync + client echo suppression, 06-07 on-device UAT]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Value-equal S->C snapshot park in ConnectionService -> changes ping -> Notifier re-snapshot (cloned from VolChanged/AppsChanged)"
    - "Fetch reply kept in a DISTINCT slot from the live push; identity-tracked (fresh String per decode) so a stale/unrelated changes ping never consumes it"
    - "Move-to-head history dedupe: record removes any existing equal entry then prepends (consecutive dedupe generalizes to reuse-promotes, D-06)"
    - "Async fetch outcome surfaced via an identity-tracked ClipFetchEvent set BEFORE the first await so the same-ping screen listener shows exactly one snackbar"

key-files:
  created:
    - "app/remote_control/lib/clipboard/clip_store.dart"
    - "app/remote_control/lib/clipboard/clipboard_screen.dart"
    - "app/remote_control/test/clipboard/clip_store_test.dart"
  modified:
    - "app/remote_control/lib/net/connection_service.dart"
    - "app/remote_control/test/connection_service_test.dart"
    - "app/remote_control/lib/hub/hub_screen.dart"

key-decisions:
  - "clipFetchReply is a String? getter (plan-specified) but identity-tracked by the notifier: each clip.set reply frame decodes to a fresh String instance, so an unrelated changes ping (identical reference) is never mistaken for a new Fetch reply — no seq/counter added"
  - "HistoryStore.record does move-to-head-with-dedupe (remove existing equal, prepend, cap 5) rather than head-only consecutive dedupe: this is the only coherent design that satisfies BOTH consecutive dedupe AND reuse-moves-to-head (D-06) without duplicating an entry"
  - "clipTextTooLarge measures UTF-8 BYTE length (utf8.encode) not code units — the faithful proxy for the encoded frame size against the 64 KB tungstenite cap (T-06-16b); a 48 KiB code-unit cap could reach ~192 KB of bytes"
  - "Send hard cap is a top-level pure predicate (clipTextTooLarge) so it is unit-testable without a ConnectionService, matching the house 'test the pure seams' pattern (apps_store/volume_store)"

patterns-established:
  - "Fetch-outcome snackbar off the raw service.changes stream (identity-tracked ClipFetchEvent) because the value-equal ClipViewState does not rebuild on an empty-PC Fetch — mirrors the apps err-toast pattern"
  - "The screen builds the ClipNotifier in initState BEFORE subscribing to changes so the notifier consumes the Fetch reply first and the screen sees the fresh event on the same ping"

requirements-completed: [CLIP-01, CLIP-02, CLIP-04]

# Metrics
duration: ~30min
completed: 2026-07-12
---

# Phase 6 Plan 05: Clipboard Client Screen Summary

**The manual Clipboard slice on the phone — one-tap Send to PC (clip.set), Fetch from PC (clip.get → phone clipboard), and a persistent last-5 history that re-pushes entries to the PC — wired to the 06-04 server seam via a value-equal ClipSnapshot + a distinct identity-tracked fetch-reply slot in ConnectionService, a move-to-head PrefsKv history store, and a ClipboardScreen + hub tile per 06-UI-SPEC.**

## Performance

- **Duration:** ~30 min
- **Completed:** 2026-07-12
- **Tasks:** 3 (2 TDD)
- **Files:** 6 (3 created, 3 modified)

## Accomplishments
- **ConnectionService clip arms (Task 1):** a value-equal `ClipSnapshot(text)` parked from `clip.changed` (the live push) plus a DISTINCT `_clipFetchReply` slot parked from the `clip.set` frame that answers `clip.get` — kept separate so an explicit Fetch is never confused with an auto-sync push. Both S→C only, never routed to the driver, no payload logged (T-06-09).
- **ClipNotifier + history store (Task 2):** `HistoryStore` over `PrefsKv` (`clip.history`, non-secret → PrefsKv only, T-06-17) with `record` doing move-to-head dedupe + cap-5 (D-06), corruption-tolerant. `ClipNotifier` clones `VolumeNotifier`: `send` (records + `clip.set`, refuses over the `clipTextTooLarge` UTF-8 byte cap, T-06-16b), `fetch` (`clip.get`, consumes the reply → phone clipboard + record), `reuse` (re-push + promote). `ClipViewState` value-equal (history + connection gating).
- **Clipboard screen + hub tile (Task 3):** `ClipboardScreen` renders the Send/Fetch key-cap action row (pressed accent flash + haptic, gated on connection) and the "Recent" last-5 history (tap → reuse + snackbar; empty state), with a deliberate placeholder gap where the 06-06 auto-sync row + honesty note will land. Send/Fetch/reuse snackbars per the 06-UI-SPEC Copywriting Contract. The Clipboard `HubTileSpec` (`Icons.content_paste`) inserts after Apps, before Power → final order Trackpad, Media, Apps, Clipboard, Power, Presenter, Browser.

## Task Commits

Each task was committed atomically (TDD tasks: test → feat):

1. **Task 1 (RED): ClipSnapshot + fetch-reply park cases** — `daf05a3` (test)
2. **Task 1 (GREEN): ConnectionService ClipSnapshot + fetch-reply arms** — `99a3c99` (feat)
3. **Task 2 (RED): HistoryStore + cap-helper + ClipViewState cases** — `62d959d` (test)
4. **Task 2 (GREEN): ClipNotifier + history PrefsKv store** — `da0b023` (feat)
5. **Task 3: Clipboard screen (Send/Fetch + history) + hub tile** — `fc71d7d` (feat)

## Files Created/Modified
- `app/remote_control/lib/net/connection_service.dart` — `ClipSnapshot` class, `_clipSnapshot`/`clipSnapshot` + `_clipFetchReply`/`clipFetchReply` fields+getters, `_onFrame` ClipChangedMsg/ClipSetMsg arms
- `app/remote_control/test/connection_service_test.dart` — ClipSnapshot value-equality + clip.changed park + clip.set fetch-reply park cases
- `app/remote_control/lib/clipboard/clip_store.dart` (created) — `HistoryStore`, `ClipViewState`, `ClipNotifier`, `clipTextTooLarge`/`kClipMaxBytes`, `ClipSendResult`/`ClipFetchOutcome`/`ClipFetchEvent`, providers
- `app/remote_control/test/clipboard/clip_store_test.dart` (created) — HistoryStore persist/dedupe/reuse-to-head/cap-5/corruption, clipTextTooLarge byte cap, ClipViewState equality
- `app/remote_control/lib/clipboard/clipboard_screen.dart` (created) — `ClipboardScreen` + Send/Fetch key-cap buttons, Recent history, empty state
- `app/remote_control/lib/hub/hub_screen.dart` — Clipboard `HubTileSpec` inserted after Apps

## Decisions Made
- **Identity-tracked fetch reply, no seq counter.** `clipFetchReply` stays a plain `String?` getter (plan-specified). The notifier baselines the current reply reference at `fetch()` time and consumes only when `!identical(current, baseline)`. Because each inbound `clip.set` frame decodes to a fresh String, a real reply is always a new reference, while an unrelated `changes` ping (e.g. a `clip.changed` push) leaves `clipFetchReply` reference-identical and is correctly skipped. This handles the race without touching the ConnectionService API surface.
- **Move-to-head history dedupe.** `record` removes any existing equal entry, prepends, then caps at 5. Head-only "consecutive dedupe" as literally worded cannot satisfy the plan's own "reuse-moves-to-head" without producing a duplicate; the generalized move-to-head is the single coherent implementation (consecutive dedupe is the trivial case of it).
- **UTF-8 byte cap.** `clipTextTooLarge` uses `utf8.encode(text).length > 48 KiB` rather than `text.length`, because the wire frame size is a byte count against the 64 KB tungstenite cap (T-06-16b); a code-unit cap would let multibyte text blow past the frame limit.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fetch outcome event set after the first await dropped the "Copied to phone." snackbar**
- **Found during:** Task 3 (wiring the screen's fetch-outcome listener)
- **Issue:** `_applyFetchReply` originally set `_lastFetchEvent` for the copied case only AFTER `await Clipboard.setData(...)`. The screen's `changes` listener runs on the SAME reply ping, synchronously after the notifier's handler — so it read a stale `lastFetchEvent` and never showed the copied snackbar (only the empty case, which set the event synchronously, worked).
- **Fix:** Reordered `_applyFetchReply` to set `_lastFetchEvent` + publish state BEFORE the first `await`, then perform the clipboard write + history record.
- **Files modified:** app/remote_control/lib/clipboard/clip_store.dart
- **Verification:** `flutter test test/clipboard/clip_store_test.dart` green; full suite 304 passed
- **Committed in:** `fc71d7d` (Task 3 commit, alongside the screen that depends on it)

**Threat-model adherence (no deviation, noted):** the `clipTextTooLarge` UTF-8 byte cap (T-06-16b) and PrefsKv-only history (T-06-17) are the plan's `mitigate` dispositions applied in code; clipboard text is never logged (T-06-09) — the arms/store carry no logging and snackbars use fixed copy strings only.

---

**Total deviations:** 1 auto-fixed (bug, surfaced by wiring the async fetch outcome). No scope change.

## Issues Encountered
- **Listener ordering for the async Fetch outcome.** The screen must see the notifier's fresh `lastFetchEvent` on the reply ping. Resolved by (a) building the `ClipNotifier` in `initState` before the screen subscribes to `changes` (notifier consumes first) and (b) the Rule-1 reorder above (event set before the first await). Both are documented inline.

## Known Stubs
- None. The auto-sync toggle + `clip.changed` apply-vs-ignore gate + the persistent honesty note are DEFERRED to 06-06 by plan (a placeholder gap is left on the screen) — this is a planned scope boundary, not a stub. Real Send/Fetch/reuse against a live PC clipboard are on-device UAT (06-07); the wire path is fully implemented.

## Threat Flags
None — no new security surface beyond the plan's threat register. `clip.set`/`clip.get` ride the existing `sendReliable` path; the client Send cap keeps frames under the WS limit (T-06-16b); history is non-secret PrefsKv (T-06-17); no clipboard text is logged (T-06-09); no new packages (Clipboard is a flutter/services built-in — T-06-SC).

## Verification Evidence
- `flutter test test/connection_service_test.dart` → 22 passed (incl. 3 new clip cases).
- `flutter test test/clipboard/clip_store_test.dart` → 10 passed (dedupe, reuse-to-head, cap-5, persist, corruption, byte cap, view equality).
- `flutter test test/hub` → 2 passed (registry + grid, 7 tiles).
- `flutter analyze lib/clipboard lib/net lib/hub` → No issues found.
- Full app suite: `flutter test` → 304 passed.
- Real Send/Fetch/reuse and live `clip.changed` against a PC are on-device UAT (06-07) — not CI-testable (needs a real Windows clipboard + server).

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- The manual Clipboard slice is code-complete on the phone (CLIP-01/02/04). 06-06 can layer auto-sync (CLIP-03) into the reserved screen gap: the `ClipSnapshot` live-push park is already in place for the client-gated `clip.changed` apply, and the history store + notifier are ready to receive the toggle.
- No blockers.

---
*Phase: 06-apps-clipboard*
*Completed: 2026-07-12*

## Self-Check: PASSED

- Created files verified on disk: clip_store.dart, clipboard_screen.dart, clip_store_test.dart, 06-05-SUMMARY.md
- Task commits verified in git log: daf05a3, 99a3c99, 62d959d, da0b023, fc71d7d
