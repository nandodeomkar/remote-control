---
phase: 07-server-shell-dashboard-polish
verified: 2026-07-15T13:10:00Z
status: human_needed
score: 5/5 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Tray survives Explorer restart"
    expected: "Kill+restart explorer.exe (Task Manager); the Remote Control tray icon reappears and its menu (Settings/Pair new/Pause/Quit) still works"
    why_human: "TaskbarCreated re-registration is handled inside tray-icon 0.24's Win32 proc; only a live Explorer restart on-device proves the icon actually comes back"
  - test: "Pause input keeps the connection alive"
    expected: "With a phone connected, click tray Pause input — cursor/keys stop moving the PC, tray icon turns gray, but the phone stays connected (chip stays green); unpause resumes input without re-pairing"
    why_human: "Requires a live paired phone + observing that the WebSocket session survives while injection is gated — runtime behavior grep cannot confirm"
  - test: "Autostart survives a real reboot"
    expected: "Enable 'Start with Windows' in Settings, reboot the PC; the server is running in the tray after login. Disable it, reboot again; the server does NOT auto-start"
    why_human: "HKCU Run-key boot behavior is an OS-integration effect only a reboot can confirm (autostart_round_trip_hkcu test is #[ignore], on-device only)"
  - test: "Revoked phone is disconnected and must re-pair"
    expected: "With a phone paired+connected, open Settings, click Revoke on that device row; the phone's live session drops immediately and it can only reconnect by pairing a fresh 6-digit PIN (stored token no longer works)"
    why_human: "Needs a second device (the phone) to observe the live force-disconnect + re-pair requirement end to end"
  - test: "Firewall-blocked port shows a startup tray warning with a fix hint"
    expected: "With Windows Firewall on and no allow-rule for the port, start the server; a toast/tray warning appears telling the owner to allow Remote Control through the firewall, and the tray icon shows the warning (red) state"
    why_human: "Requires a real blocked-firewall profile at startup; the inbound_allowed COM query test is #[ignore] (touches live firewall state)"
  - test: "Port-in-use produces a distinct warning, not a silent crash"
    expected: "Start a second copy of the server (or occupy the port); it surfaces a 'port already in use — change it in Settings' toast rather than an unexplained exit"
    why_human: "Needs the real AddrInUse startup path + toast observation on-device"
  - test: "UIPI status shows on the phone instead of failing silently"
    expected: "Focus an elevated (Run-as-administrator) window on the PC, then move/click from the phone; within ~250ms the phone shows the advisory banner 'Can't control this window — it's running as administrator', which auto-dismisses ~4s later and never blocks a touch"
    why_human: "Requires an elevated foreground window on the PC + the phone to observe the pushed input.blocked banner; real UIPI drop is not grep-observable"
  - test: "Dashboard identity + dark-minimal polish on-device"
    expected: "The home screen shows the 8 tool tiles in a uniform 2x4 grid on #0E0F12 with the blue #4C8DFF accent; the persistent Trackpad quick-bar is present at the bottom of every tool screen (except Trackpad itself); offline disables the tiles but keeps the settings gear reachable"
    why_human: "Visual layout/appearance and offline-disable feel are on-device visual checks"
  - test: "Haptic toggle + keep-awake behave correctly"
    expected: "Taps/keys tick with haptics ON and go silent with the Settings toggle OFF; the screen stays awake during trackpad and presenter use (including a Presenter->quick-bar->Trackpad->back path) and sleeps normally otherwise"
    why_human: "Haptic feel and screen keep-awake are physical-device behaviors; the ref-count logic is unit-tested but the platform effect is not"
  - test: "Behavior-sensitive review fixes (CR-01, WR-02, WR-05, WR-08) hold under real conditions"
    expected: "Held keys/modifiers/drag are released on screen-pop and mid-drag disconnect (no phantom input); overlapping reconnect dials don't bind to a stale target; a broken GPU/RDP GL stack degrades the settings window without taking the tray down; an alive-but-not-reading client still gets held input released within the CONN-07 10s deadline"
    why_human: "07-REVIEW-FIX flagged these as requires-human-verification (lifecycle/liveness/degrade paths with no automated coverage of the real timing)"
---

# Phase 7: Server Shell, Dashboard & Polish — Verification Report

**Phase Goal:** The system is a daily-driver product — the server lives quietly in the tray with settings, autostart, and device revoke; failures surface honestly (firewall self-test, UIPI status); and the app gets its final dashboard identity with dark-minimal polish, haptics, and keep-awake.
**Verified:** 2026-07-15T13:10:00Z
**Status:** human_needed
**Re-verification:** No — initial verification (a code review + fix pass ran separately; this is the goal-backward verification)

## Goal Achievement

### Observable Truths

| # | Truth (ROADMAP Success Criteria) | Status | Evidence |
| --- | --- | --- | --- |
| 1 | Server lives in the tray with a device-count tooltip; pause-input drops input while keeping the connection alive; quit works; the icon survives an Explorer restart | ✓ VERIFIED (code) | `shell/tray.rs`: `Tray` builds icon + Settings/Pair/Pause/Quit menu, count-only `tooltip_text`, 3 icon states; `shell/mod.rs`: Pause flips `pause_tx`, Quit calls `event_loop.exit()`+`process::exit(0)`, tooltip fed from `conn_count` watch; `main.rs:227-228,362-371` real `conn_count` sender bumped per-session (`session.rs:376/423`); TaskbarCreated re-register handled by tray-icon 0.24 (documented). Runtime → human |
| 2 | With autostart enabled the server starts with Windows; the toggle turns it off cleanly | ✓ VERIFIED (code) | `autostart.rs`: `enable/disable/is_enabled` over `auto_launch` HKCU Run, absolute exe, degrade-never-panic; wired in `settings.rs:394-423` (checkbox → `autostart::enable/disable`, persists to config, reflects registry truth on error). Reboot effect → human |
| 3 | Settings window manages device name, port, clipboard sync, and the paired list; a revoked phone is disconnected and must re-pair | ✓ VERIFIED (code) | `settings.rs`: name/port/clip-sync fields bound to shared `config`, per-row Revoke → `crate::revoke_device`, Pair-new → `begin_on_demand_pairing`; `main.rs:432-445` revoke bumps epoch + change-signal; `session.rs:274-290` revoke `select!` branch force-disconnects live session; config persisted atomically (`config.rs` save, WR-04). Two-device re-pair → human |
| 4 | Firewall-blocked port → tray warning + fix hint at startup; UIPI-blocked input → clear phone status instead of silent failure | ✓ VERIFIED (code) | `firewall.rs`: read-only `inbound_allowed` (INetFwPolicy2) + `classify_bind_error`; `main.rs:257-300` startup self-test → `notify_firewall_warning` + Warning icon; `input_thread.rs`: `foreground_blocked()` + debounced `maybe_check_uipi` → `blocked_tx` epoch; `session.rs:298-311` authed-gated `input.blocked` push; client `connection_service.dart:618-623` parks `InputBlockedSnapshot`; `uipi_banner.dart` renders locked advisory copy. Real block/elevated-window → human |
| 5 | Dashboard shows 8 tool tiles + persistent trackpad quick-bar on every screen; dark-minimal theme (#0E0F12, blue accent); haptic toggle; keep-awake during trackpad/presenter | ✓ VERIFIED (code) | `hub_screen.dart`: `kHubTiles` = exactly 8 tiles (Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser), uniform 2×4 grid; `quick_bar_scaffold.dart` wraps every tool screen with 56px Trackpad bar + UIPI banner; `tokens.dart` `kBg=#0E0F12`, `kAccent=#4C8DFF`; `main.dart:102-103` `home:HubScreen`/`theme:buildAppTheme()`; `haptics.dart` gated `hapticTick` + `settings_screen.dart` toggle; `keep_awake.dart` ref-count used by trackpad+presenter `initState/dispose`. Visual/haptic feel → human |

**Score:** 5/5 truths code-verified (artifacts exist, substantive, wired, data flows). All 5 additionally require on-device runtime confirmation (see Human Verification Required).

### Required Artifacts

| Artifact | Expected | Status | Details |
| --- | --- | --- | --- |
| `server/server-windows/src/shell/tray.rs` | Tray icon + menu + count tooltip | ✓ VERIFIED | 176 lines; menu, 3 states, count-only tooltip |
| `server/server-windows/src/shell/mod.rs` | Shell thread + event loop wiring | ✓ VERIFIED | 327 lines; pause/quit/tooltip/settings routing |
| `server/server-windows/src/shell/settings.rs` | egui settings window | ✓ VERIFIED | 594 lines; name/port/clip/autostart/revoke/pair/firewall-hint |
| `server/server-windows/src/autostart.rs` | HKCU Run toggle | ✓ VERIFIED | enable/disable/is_enabled, wired in settings.rs |
| `server/server-windows/src/firewall.rs` | Read-only self-test + bind classifier | ✓ VERIFIED | inbound_allowed + classify_bind_error, wired in main.rs |
| `server/server-windows/src/notify.rs` | PIN + firewall toasts | ✓ VERIFIED | notify_pin/notify_firewall_warning used in main.rs |
| `server/server-windows/src/input_thread.rs` | UIPI foreground detection | ✓ VERIFIED | foreground_blocked + debounced epoch push |
| `server/server-core/src/transport/session.rs` | conn_count / revoke / input.blocked branches | ✓ VERIFIED | try_send (WR-08), revoke + blocked select! arms |
| `app/.../hub/hub_screen.dart` | 8-tile 2×4 dashboard | ✓ VERIFIED | kHubTiles (8), uniform grid, QuickBarScaffold wrap |
| `app/.../widgets/quick_bar_scaffold.dart` | Persistent quick-bar + UIPI host | ✓ VERIFIED | 56px bar on every tool screen + banner overlay |
| `app/.../widgets/uipi_banner.dart` | UIPI advisory client surface | ✓ VERIFIED | Reads InputBlockedSnapshot, ~4s auto-dismiss, IgnorePointer |
| `app/.../theme/tokens.dart` | #0E0F12 + #4C8DFF palette + theme | ✓ VERIFIED | kBg/kAccent + buildAppTheme |
| `app/.../settings/haptics.dart` | Gated haptic tick + toggle store | ✓ VERIFIED | hapticTick gate + Riverpod provider + hot-path cache |
| `app/.../widgets/keep_awake.dart` | Ref-counted wakelock | ✓ VERIFIED | acquire/release, used by trackpad+presenter |
| `protocol/fixtures/input_blocked/01-input-blocked.json` | Golden fixture (proto 1.3) | ✓ VERIFIED | Present |

### Key Link Verification

| From | To | Via | Status |
| --- | --- | --- | --- |
| tray Pause menu | server pause seam | `pause_tx.send` in shell/mod.rs → `pause_rx` in ServerDeps | ✓ WIRED |
| conn_count sessions | tray tooltip | watch sender (main.rs) → EventLoopProxy Tooltip | ✓ WIRED |
| settings Revoke | live session drop + persist | `revoke_device` → `revoke_tx` epoch (session.rs branch) + auth.changes → config save | ✓ WIRED |
| settings autostart toggle | HKCU Run | `autostart::enable/disable` | ✓ WIRED |
| startup self-test | tray warning | `firewall::inbound_allowed` → `notify_firewall_warning` + Warning icon | ✓ WIRED |
| input thread UIPI | phone banner | `foreground_blocked` → `blocked_tx` → session input.blocked push → `InputBlockedMsg` → `_inputBlocked` → UipiBanner | ✓ WIRED |
| hub tile tap | tool screen + quick-bar | `HubScreen._open` → `QuickBarScaffold` | ✓ WIRED |
| app root | dashboard + theme | `main.dart home:HubScreen theme:buildAppTheme` | ✓ WIRED |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| --- | --- | --- | --- | --- |
| tray tooltip | conn_count | real per-session bump/decrement in session.rs (not hardcoded 0) | Yes | ✓ FLOWING |
| settings paired list | auth.paired_records() | AuthManager seeded from config.toml, live | Yes | ✓ FLOWING |
| UipiBanner | inputBlockedSnapshot | parked from real InputBlockedMsg push | Yes | ✓ FLOWING |
| hub grid | kHubTiles | static registry of 8 tiles (by design — the tile set is fixed) | Yes (intentional static) | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| --- | --- | --- | --- |
| Rust workspace tests | `cargo test --workspace` (per task note + 07-REVIEW-FIX) | 165 passed | ✓ PASS (reported; not re-run — OS-integration tests are #[ignore], require on-device) |
| Flutter tests | `flutter test` (per task note) | 351 passed | ✓ PASS (reported; not re-run) |
| Debt-marker scan | grep TBD/FIXME/XXX in phase-modified src | none found | ✓ PASS |

Note: full suites were not re-run in this verification pass (they were run green in the code-review-fix pass immediately prior). Autostart/firewall integration tests are deliberately `#[ignore]` and require on-device execution — routed to human verification.

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
| --- | --- | --- | --- | --- |
| SRV-01 | 07-05/06 | Tray: status tooltip, pause, quit | ✓ SATISFIED (code) | tray.rs + shell/mod.rs + conn_count wiring |
| SRV-02 | 07-03/08 | Autostart toggle | ✓ SATISFIED (code) | autostart.rs + settings.rs toggle |
| SRV-03 | 07-01/05/07/08/12 | Settings: name/port/revoke/clip-sync | ✓ SATISFIED (code) | settings.rs + revoke_device + config persistence |
| SRV-04 | 07-03/06/08 | Firewall startup warning | ✓ SATISFIED (code) | firewall.rs + main.rs self-test + notify |
| SRV-05 | 07-02/04/05/11 | UIPI status on phone | ✓ SATISFIED (code) | input_thread.rs + session push + uipi_banner.dart |
| UI-01 | 07-13 | Dashboard + persistent quick-bar | ✓ SATISFIED (code) | hub_screen.dart (8 tiles) + quick_bar_scaffold.dart |
| UI-02 | 07-09/10/12 | Dark theme + haptics + keep-awake | ✓ SATISFIED (code) | tokens.dart + haptics.dart + keep_awake.dart |

All 7 declared requirement IDs are covered by plans and implemented in code. No orphaned or unclaimed requirement IDs for Phase 7.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| --- | --- | --- | --- | --- |
| — | — | No TBD/FIXME/XXX in phase-modified source | — | None |
| autostart.rs / firewall.rs | top | `#![allow(dead_code)]` | ℹ️ Info | Intentional — primitives built in Wave 1, consumed by later-wave shell/settings; both are now actually wired (verified). Not a stub. |

IN-01..IN-08 remain as tracked debt from 07-REVIEW (out of scope for the fix pass); none are blockers. WR-04 note: single-writer config serialization + graceful-shutdown flush were deliberately deferred; the atomic rename eliminates the severe corruption failure mode. This is an accepted follow-up, not a phase-goal blocker.

### Human Verification Required

This phase is fundamentally an OS-integration + on-device product phase. Every observable truth is code-complete and wired, but the runtime behaviors below can only be confirmed on real hardware (a Windows PC + the paired Android phone). See the `human_verification` frontmatter for the full structured list (10 items):

1. Tray survives an Explorer restart
2. Pause input keeps the connection alive
3. Autostart survives a real reboot (and toggles off cleanly)
4. Revoked phone is disconnected and must re-pair (needs the phone)
5. Firewall-blocked port shows a startup tray warning with a fix hint
6. Port-in-use produces a distinct warning, not a silent crash
7. UIPI status shows on the phone (elevated window) instead of failing silently
8. Dashboard identity / dark-minimal polish on-device (8 tiles, quick-bar, offline-disable)
9. Haptic toggle + keep-awake behave correctly
10. Behavior-sensitive review fixes (CR-01 held-input lifecycle, WR-02 overlapping dial, WR-05 GL degrade, WR-08 liveness) hold under real conditions

### Gaps Summary

No gaps. All 5 success criteria are implemented in substantive, fully-wired code with real data flow; all 7 requirement IDs are covered; no stubs, no unreferenced debt markers, and the automated test suites were reported green in the immediately-prior code-review-fix pass. The phase does not PASS outright only because its acceptance criteria are inherently runtime/on-device (tray survival, reboot autostart, live revoke-disconnect, firewall/UIPI OS behavior, visual polish, haptic/keep-awake feel) — these route to an on-device UAT list rather than blocking. Recommend proceeding to on-device UAT; treat the 10 human-verification items as the acceptance checklist.

---

_Verified: 2026-07-15T13:10:00Z_
_Verifier: Claude (gsd-verifier)_
