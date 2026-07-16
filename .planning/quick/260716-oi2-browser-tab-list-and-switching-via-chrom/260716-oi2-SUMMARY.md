---
quick_id: 260716-oi2
type: quick
status: complete
requirements: [BROW-01]
subsystem: browser-tabs
tags: [extension, mv3, protocol-1.4, ext-listener, flutter-ui, docs]
commits:
  - b643852
  - a8373c2
  - 920fbeb
  - 104cf04
  - 44629e4
key-files:
  created:
    - extension/manifest.json
    - extension/background.js
    - extension/README.md
    - protocol/fixtures/tabs/ (5 fixtures)
    - server/server-core/src/transport/ext.rs
    - server/server-core/tests/ext_relay.rs
    - app/remote_control/lib/browser/tabs_store.dart
    - app/remote_control/test/browser/tabs_store_test.dart
  modified:
    - protocol/SPEC.md
    - server/server-core/src/codec/json.rs
    - server/server-core/src/executors/{mod,mock}.rs
    - server/server-core/src/transport/{mod,listener,session}.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-windows/src/main.rs
    - app/packages/remote_protocol/lib/src/json_codec.dart
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/browser/browser_screen.dart
    - README.md
    - DISTRIBUTION.md
completed: 2026-07-16
---

# Quick Task 260716-oi2: Browser Tab List + Switching via Chrome/Edge Extension — Summary

**One-liner:** Phone Browser screen now lists the PC browser's live tabs (title + favicon, active accent-marked) and can switch/close them, fed by a new zero-dependency MV3 "Tab Bridge" extension talking to a second 127.0.0.1-only WS listener (port 17779) that the server relays over an additive protoVersion 1.4 `tabs.*` family.

## What Was Built (all 5 tasks)

**Execution note:** Tasks 1–2 were executed by a prior session and recovered
from an orphaned worktree; Task 3 was recovered and verified; Tasks 4–5 were
executed this session on the main tree (no worktree isolation — deliberate).

### Task 1 — MV3 Tab Bridge extension walking skeleton (b643852)
- `extension/` top-level artifact: manifest.json (MV3, permissions tabs/favicon/alarms, no host_permissions) + background.js (~300-line vanilla-JS service worker, zero deps).
- WS client to `ws://127.0.0.1:17779` with 20s ext.ping keepalive (A1), exponential backoff 1/2/4/8/10s, chrome.alarms resurrection every 30s (A5), reconnect-if-closed guard on every tabs event.
- Debounced (200ms) FULL tabs.state snapshots — never diffs; caps: 50 tabs, 4096-char icon, 56 KB frame budget with tail icon-stripping; favicons via the `_favicon/` permission endpoint, cached (A3).
- tabs.activate (update + window focus) / tabs.close execution with swallowed rejections; no tab title/url ever logged.

### Task 2 — Protocol 1.4 contract (a8373c2)
- SPEC.md drift fix (header 1.1 → 1.4, 1.2/1.3 amendment notes backfilled) + tabs.* family in §7, §11 pause list additions, new §15 "Extension leg (localhost)".
- 5 golden fixtures in `protocol/fixtures/tabs/` registered in BOTH hard-coded harnesses (Rust `codec_fixtures_tabs`, Dart `tabs fixtures` group).
- Rust: TabInfo/TabsState in executors, 4 payload structs + Msg variants + codec arms, SERVER_PROTO_VERSION 1.3 → 1.4, beacon fixture bumped in lockstep.
- Dart: TabInfo + TabsListMsg/TabsChangedMsg/TabsActivateMsg/TabsCloseMsg, decode/encode wired, barrel exports.

### Task 3 — Server relay (920fbeb, recovered + verified)
- `transport/ext.rs`: DEFAULT_EXT_PORT 17779, ExtCmd, TabsRelay (watch + mpsc try_send), `run_ext` single-task loop — loopback assert, 64 KB caps, single-extension newest-wins, watch reset to default on any ext disconnect (flips the phone to the hint state).
- Tabs executor trait (fire-and-forget activate/close), authed-gated `tabs.changed` session push (apps.changed clone), router: tabs.list read exemption while paused, tabs.activate/close executor-bound drops.
- main.rs composition: RC_EXT_PORT override, bind failure degrades to no-tabs (never kills the server).
- Tests: 7 ext_relay scenarios (incl. oversize-frame kill + recover), router pause gates, `tabs_no_push_preauth` + authed push/disconnect-hint integration tests.

### Task 4 — Flutter tab UI (104cf04)
- TabsSnapshot parked in ConnectionService from tabs.changed AND the tabs.list reply (no payload logging).
- `lib/browser/tabs_store.dart`: TabsViewState + TabsNotifier (primeList/activate/close) + tabsStateProvider.
- Browser screen: tab section above the untouched 7-action macro grid — install-hint card when disconnected, tab rows (favicon, ellipsized title, active tab kAccent border), tap-down = activate, swipe-dismiss OR long-press = close, actions gated on ChipStatus.connected.
- Tests: tabs_store_test.dart (value equality + command wiring) + browser_screen_test.dart extensions, all 09-04 pinned assertions kept green.

### Task 5 — Docs + distribution (44629e4)
- extension/README.md: user walkthrough — what it is (localhost-only, titles+favicons to your own server, never full URLs off the machine), Chrome + Edge load-unpacked install, troubleshooting (SW inactive normal, keep the folder, RC_EXT_PORT = edit PORT const + reload, "Read your browsing history" = tabs permission); developer smoke-test section kept verbatim.
- Root README.md: "What you get" bullet + "### Browser tab list (optional)" subsection at the end of the Install section.
- DISTRIBUTION.md: "Browser extension" build step (`Compress-Archive -Path extension -DestinationPath RemoteControl-Extension-v1.0.0.zip`), attached beside exe + apk; stale "two artifacts" intro wording fixed.

## Commits

| Commit | Subject |
|--------|---------|
| b643852 | feat(quick-260716-oi2): MV3 Tab Bridge extension walking skeleton |
| a8373c2 | feat(quick-260716-oi2): protocol 1.4 tabs.* family + SPEC drift fix |
| 920fbeb | feat(quick-260716-oi2): server tab relay — ext listener, TabsRelay, session push, router gates |
| 104cf04 | feat(quick-260716-oi2): phone tab list — TabsNotifier + Browser screen section |
| 44629e4 | docs(quick-260716-oi2): extension walkthrough + release docs |

## Verification (Task 5 final run, all green)

- `cargo test -p server-core`: 141 passed, 0 failed (102 unit + 7 ext_relay + 8 fixtures + 24 integration)
- `flutter analyze`: no issues; `flutter test`: 472 passed, 0 failed
- `dart test` (remote_protocol): 12 passed, 0 failed

## Deviations from Plan

**1. [Task 4] Dismissible confirmDismiss gating pattern**
- Swipe-close gating implemented via `confirmDismiss` returning false when not authed (the plan's locked pattern) — noted here because it doubles as the inert-when-unauthed mechanism for swipes, distinct from the tap/long-press enabled flag.

**2. [Task 4] Long-press close gating**
- Long-press = close is gated on the same `enabled` (ChipStatus.connected) flag as tap-activate so an unauthed long-press is inert; documented in the row's doc comment alongside the accepted per-screen long-press semantics difference (apps screen long-press = pin).

**3. [Task 5, minor] DISTRIBUTION.md intro wording**
- "the two Remote Control release artifacts" updated to drop the stale count now that a third artifact (extension zip) exists — same-file consistency fix within scope.

## OUTSTANDING — Human E2E Checklist (from Task 5 human-check)

Not yet performed; must pass (or failures filed back into the relevant task) before the feature is considered field-verified:

1. **Extension load-unpacked smoke (A2–A5):** chrome://extensions → Developer mode → Load unpacked → `extension/`. SW console: no manifest errors; WS connect logs a connection-refused network error, NOT a SecurityError (A2); `_favicon` fetch logs image/png nonzero (A3); `chrome.tabs.query` logs count + true (A4); `rc-reconnect` alarm at periodInMinutes 0.5 (A5).
2. **Keepalive (A1):** run the release server (confirm ext listener log line on 127.0.0.1:17779), load the extension, leave Chrome idle 5+ minutes — the SW stays "active" (20s ext.ping) and the phone list stays live.
3. **Live tab list walkthrough:** phone Browser screen lists tabs with favicons, active tab accent-marked; PC-side open/close/switch reflects within ~1 s; tap a row → PC switches (window focused); swipe a row → tab closes; long-press → tab closes.
4. **Fallback hint:** quit Chrome entirely → phone shows the install hint within ~2 s and all 7 macro keys still fire; relaunch Chrome → list returns without touching the phone.
5. **Pause semantics:** pause from the tray → tapping a tab does nothing on the PC; the list still refreshes on screen re-open (tabs.list read exemption).
6. **Edge (A6, optional):** load unpacked via edge://extensions, confirm the list appears (single-extension newest-wins — whichever browser connected last owns the list, expected).

## Self-Check: PASSED

- extension/README.md, README.md, DISTRIBUTION.md — all present with Task 5 content
- Commits b643852, a8373c2, 920fbeb, 104cf04, 44629e4 — all present in git log
