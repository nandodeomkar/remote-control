---
phase: 06-apps-clipboard
plan: 06
subsystem: ui
tags: [flutter, riverpod, clipboard, auto-sync, shared_preferences, lifecycle, privacy]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    plan: 05
    provides: "ClipNotifier send/fetch/reuse + HistoryStore + ClipboardScreen (Send/Fetch + Recent history) with the reserved auto-sync gap; ConnectionService value-equal ClipSnapshot (clip.changed) + clipFetchReply slot"
  - phase: 06-apps-clipboard
    plan: 04
    provides: "server clip.changed authed-gated push + server-side sensitive/>16 KiB/echo skip; no implicit after-auth snapshot"
provides:
  - "AutoSyncStore (PrefsKv key clip.autosync, default OFF, D-03) — local persisted toggle, always toggleable regardless of connection"
  - "ClipSyncPolicy — pure IO-free apply/echo/resume seam: PC->phone applyPush client-gated on the toggle (A4) + value-equality echo suppression (D-05); phone->PC syncOnResume send-vs-skip (D-08); noteSynced tracks manual moves"
  - "ClipNotifier live auto-sync: autoSyncOn on ClipViewState, setAutoSync, identity-tracked clip.changed apply, syncOnResume; send/reuse/fetch noteSynced"
  - "ClipboardScreen auto-sync switch row + persistent honesty note + AppLifecycleListener resume hook"
affects: [06-07 on-device UAT]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure IO-free decision seam (ClipSyncPolicy) with injected write/record/send — the clock-free sibling of VolumeSliderPolicy, so apply/echo/resume gates unit-test without Flutter/Riverpod/ConnectionService (house 'test the pure seams' pattern)"
    - "Client-gated apply: server pushes clip.changed always post-auth; the CLIENT decides apply-vs-ignore by its local toggle (RESEARCH A4)"
    - "Value-equality echo suppression via a single lastSynced tracking the last value that crossed in EITHER direction (applied push, sent phone clip, or a manual move noted by noteSynced) — complements the server fingerprint suppression (06-04)"
    - "Identity-tracked clip.changed apply: each real push parks a fresh ClipSnapshot instance, so identity comparison applies each genuine push exactly once (value-level echo handled separately by the policy)"

key-files:
  created: []
  modified:
    - "app/remote_control/lib/clipboard/clip_store.dart"
    - "app/remote_control/test/clipboard/clip_store_test.dart"
    - "app/remote_control/lib/clipboard/clipboard_screen.dart"

key-decisions:
  - "Echo/apply/resume logic factored into a pure injectable ClipSyncPolicy (VolumeSliderPolicy sibling) rather than tested through the Riverpod ClipNotifier: the notifier needs a fake ConnectionService + platform Clipboard channel + ProviderContainer, whereas the pure seam tests the exact same decisions IO-free — matching the existing clip_store_test posture (HistoryStore + clipTextTooLarge tested purely, never the notifier)"
  - "A single lastSynced value (not separate send/apply fields) is the whole echo model: whatever last crossed in either direction is what a bounce would repeat, so one value suppresses both a re-applied push and a re-sent resume clip (D-05)"
  - "ClipViewState.autoSyncOn defaults to false in the constructor (named, non-required) so the 06-05 const ClipViewState(history:, connected:) test constructions still compile — additive, back-compatible"
  - "The clip.changed apply is identity-tracked on the ClipSnapshot instance (like the fetch reply) so redundant changes pings (volume/apps/status) never re-run the apply; genuine A->B->A PC changes still apply because each parks a fresh instance and the policy's lastSynced (B) differs from A"

patterns-established:
  - "Auto-sync switch is exempt from connection gating — onChanged is always wired (local preference, D-03), unlike the wire-bound Send/Fetch/history controls which mute when unauthed"
  - "AppLifecycleListener resume hook (Flutter built-in) drives phone->PC sync only on AppLifecycleState.resumed (Android 10+ background-read limit, D-08); disposed with the screen State"

requirements-completed: [CLIP-03]

# Metrics
duration: ~15min
completed: 2026-07-12
---

# Phase 6 Plan 06: Clipboard Auto-Sync Summary

**The opt-in live Clipboard slice — an always-toggleable auto-sync switch (default OFF, D-03) that, when on, applies a PC `clip.changed` push to the phone clipboard live (client-gated, RESEARCH A4) and syncs a phone copy to the PC on app resume (Android 10+ honest limit, D-08), with single-value echo suppression (D-05) so nothing loops — built as a pure IO-free ClipSyncPolicy + a PrefsKv AutoSyncStore wired into ClipNotifier, plus the switch row + persistent honesty note + AppLifecycleListener resume hook on the Clipboard screen.**

## Performance

- **Duration:** ~15 min
- **Completed:** 2026-07-12
- **Tasks:** 2 (Task 1 TDD)
- **Files:** 3 modified

## Accomplishments
- **Auto-sync store + apply/echo/resume seam (Task 1, TDD):** `AutoSyncStore` over `PrefsKv` (`clip.autosync`, default OFF via absent-key → false, D-03). `ClipSyncPolicy` is the pure, IO-free decision seam (VolumeSliderPolicy sibling) with injected `writeClipboard`/`record`/`send`: `applyPush` applies a PC→phone snapshot ONLY when auto-sync is on AND non-null AND not an echo of `lastSynced` (A4 + D-05); `syncOnResume` sends phone→PC only when on AND non-empty AND non-echo (D-08); `noteSynced` records a manual move so the server's bounce is suppressed. `ClipNotifier` wires both — `autoSyncOn` on `ClipViewState`, `setAutoSync` (persist + republish), identity-tracked `clip.changed` apply in the `changes` path, `syncOnResume` reading the phone clipboard; `send`/`reuse`/`fetch` call `noteSynced` on the value they moved.
- **Auto-sync switch row + honesty note + resume hook (Task 2):** filled the 06-05 reserved gap with `_AutoSyncRow` (label "Auto-sync clipboard" 16/600 `#E6E8EB` + Material `Switch` accent `#4C8DFF` on / inactive `#2A2D34` off, default OFF, ≥48px, ALWAYS enabled — exempt from connection gating, D-03) bound to `clip.autoSyncOn` / `notifier.setAutoSync`; the persistent `_HonestyNote` directly beneath (12/400 `#6B7280`, leading `Icons.info_outline`, exact copy "Phone → PC syncs when you open this app. PC → phone syncs live.", never hidden, D-08); and an `AppLifecycleListener` whose `onResume` calls `notifier.syncOnResume()`, disposed with the screen.

## Task Commits

Each task committed atomically (Task 1 TDD: test → feat):

1. **Task 1 (RED): failing AutoSyncStore + ClipSyncPolicy apply/echo/resume cases** — `b15dab1` (test)
2. **Task 1 (GREEN): AutoSyncStore + ClipSyncPolicy apply-gate + echo suppression** — `1987f03` (feat)
3. **Task 2: auto-sync switch row + honesty note + resume hook** — `bf276a5` (feat)

## Files Created/Modified
- `app/remote_control/lib/clipboard/clip_store.dart` — `AutoSyncStore`, `ClipSyncPolicy` (pure seam), `ClipViewState.autoSyncOn` (defaulted, value-equal), `ClipNotifier` auto-sync wiring (`_policy`, `_autoSyncOn`, `_lastSeenSnapshot`, `setAutoSync`, `syncOnResume`, `_applyPush`, `noteSynced` in send/reuse/fetch), `clipAutoSyncStoreProvider`
- `app/remote_control/test/clipboard/clip_store_test.dart` — `AutoSyncStore` default-off + persist/reload; `ClipSyncPolicy` apply-when-on / ignore-when-off / null-ignore / echo-suppressed / noteSynced-echo; `syncOnResume` send / off / echo-skip / empty; `ClipViewState.autoSyncOn` equality (13 new cases, 23 total)
- `app/remote_control/lib/clipboard/clipboard_screen.dart` — `_AutoSyncRow` + `_HonestyNote` widgets, the row/note filled into the reserved gap, `AppLifecycleListener` resume hook (init + dispose)

## Decisions Made
- **Pure ClipSyncPolicy over notifier tests.** The echo/apply/resume gates live in a pure, injectable `ClipSyncPolicy` (all IO — clipboard write, history record, `clip.set` send — passed in as callbacks), tested IO-free exactly like `VolumeSliderPolicy`. Driving these through the Riverpod `ClipNotifier` would require faking the concrete `ConnectionService`, the platform `Clipboard` channel, and a `ProviderContainer` — the existing `clip_store_test` already tests `HistoryStore` and `clipTextTooLarge` at the pure-seam level and never the notifier, so this matches the house posture.
- **One `lastSynced` value is the whole echo model (D-05).** Whatever last crossed in either direction (a push we applied, a phone clip we sent on resume, or a value the notifier moved via `noteSynced`) is precisely what a server bounce would repeat, so a single tracked value suppresses both a re-applied push and a re-sent resume clip — no separate send/apply bookkeeping.
- **Identity-tracked apply + value-tracked echo are complementary.** The `clip.changed` apply is gated on `ClipSnapshot` instance identity (each real push parks a fresh instance) so unrelated `changes` pings never re-run the apply; the value-equality echo suppression is a separate concern handled by the policy's `lastSynced`, so a genuine A→B→A PC change still applies the second A (identity differs, and `lastSynced` is B).
- **`autoSyncOn` defaulted, not required.** `ClipViewState` gains `autoSyncOn` as a defaulted named param so the 06-05 const test constructions keep compiling — additive and back-compatible.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `Switch.activeColor` is deprecated — use `activeThumbColor`**
- **Found during:** Task 2 (analyze after adding the switch)
- **Issue:** `flutter analyze lib/clipboard` flagged `activeColor` as deprecated after Flutter v3.31 (replacement `activeThumbColor`); the plan's UI-SPEC names the accent-thumb-on state but predates the API rename.
- **Fix:** Replaced `activeColor: _accent` with `activeThumbColor: _accent` (same accent-thumb-on behavior).
- **Files modified:** app/remote_control/lib/clipboard/clipboard_screen.dart
- **Verification:** `flutter analyze lib/clipboard` → No issues found.
- **Committed in:** `bf276a5` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (deprecation, mechanical). No scope change.

## Issues Encountered
- None. The 06-05 reserved gap + the parked `ClipSnapshot` live-push slot made the auto-sync layer a clean drop-in.

## Known Stubs
- None. Auto-sync applies live and syncs on resume through the real `Clipboard` API and `sendReliable`. Real live `clip.changed` apply, phone→PC resume-sync, sensitive-clip skip, and the no-echo-loop are on-device UAT (06-07) — not CI-testable (needs a real Windows clipboard + server + Android foreground lifecycle).

## Threat Flags
None — no new security surface beyond the plan's threat register (T-06-10/07b/18/SC). The apply is client-gated on the local toggle (T-06-10); echo suppression is value-equality `lastSynced` (T-06-07b); phone→PC reads happen ONLY on `AppLifecycleState.resumed` / foreground (T-06-18); no new packages — `AppLifecycleListener` and `Clipboard` are flutter built-ins, existing riverpod/shared_preferences reused (T-06-SC). No clipboard text is logged.

## Verification Evidence
- `flutter test test/clipboard/clip_store_test.dart` → 23 passed (AutoSyncStore default-off/persist/reload, ClipSyncPolicy apply/ignore/null/echo/noteSynced, syncOnResume send/off/echo-skip/empty, ClipViewState autoSyncOn equality).
- `flutter test test/clipboard` → 23 passed.
- `flutter analyze lib/clipboard` → No issues found.
- Full app suite: `flutter test` → 317 passed (up from 304).
- Live PC→phone apply, phone→PC resume-sync, sensitive-clip skip, and no-echo-loop are on-device UAT (06-07).

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- CLIP-03 complete — the Clipboard requirement set (CLIP-01/02/03/04) is code-complete on the phone. The manual send/fetch/history slice (06-05) is now a live two-way sync within platform limits.
- 06-07 (on-device UAT) is the remaining phase gate: verify live apply, resume-sync, sensitive-clip skip, and no-loop against a real Windows clipboard + server on the owner's Android device.
- No blockers.

---
*Phase: 06-apps-clipboard*
*Completed: 2026-07-12*
