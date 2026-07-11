---
phase: 05-media-power-presenter-browser
verified: 2026-07-11T06:38:28Z
status: human_needed
score: 5/5 must-haves verified (code layer); on-device confirmation pending
overrides_applied: 0
human_verification:
  - test: "Media transport controls whatever is playing system-wide (MED-01, SC1)"
    expected: "Play/pause, next, prev act on Spotify AND a YouTube browser tab — whatever is currently playing responds"
    why_human: "SMTC routing depends on the running player app; enigo VK_MEDIA_* injection cannot be observed without a real audio session"
  - test: "Volume slider is absolute and PC-side changes follow (MED-02, SC1)"
    expected: "Dragging the slider sets exact PC volume (finger wins during drag); changing volume with the PC keyboard/mixer moves the app slider within ~250ms; mute reflects PC state"
    why_human: "Requires a real IAudioEndpointVolume endpoint + hardware volume keys; the 250ms poll follow cannot be exercised in CI"
  - test: "Lock and sleep execute after slide-to-confirm; sleep SUSPENDS not hibernates (PWR-01/02, SC2)"
    expected: "Completed slide locks the PC; completed sleep slide suspends (fans off, instant resume) — NOT hibernate; session recovers on wake"
    why_human: "SetSuspendState(false,..) power-state transition needs real hardware to distinguish suspend from hibernate"
  - test: "Restart/shutdown require slide PLUS dialog confirm — no single-action path (PWR-03, SC3)"
    expected: "Restart/shutdown show the red countdown dialog and fire ONLY on its confirm press; letting it reach 0 cancels; a partial slide springs back sending nothing; the PC actually reboots/powers off"
    why_human: "Destructive real-hardware action; the two-gesture + server-confirm round-trip and actual reboot/poweroff must be observed live"
  - test: "Presenter drives slides + blank in PowerPoint with an elapsed timer (PRES-01/02, SC4)"
    expected: "Start show (F5), tap zones advance/retreat slides, Blank (B), End show (Esc) drive a focused PowerPoint/Impress slideshow; the timer runs, pauses on tap, resets on hold; screen stays awake"
    why_human: "Requires a focused PowerPoint slideshow window; key-macro effect on the presentation cannot be verified from code"
  - test: "Browser macros act on the focused browser incl. zoom (BROW-01, SC5)"
    expected: "Back/forward, new/close tab, refresh, zoom in/out act on the focused browser window; zoom chord (Ctrl+Plus/Minus) actually zooms"
    why_human: "Requires a focused browser; zoom chord behavior varies by layout (Pitfall 11 — Ctrl+'=' fallback if Ctrl+Plus fails)"
---

# Phase 5: media-power-presenter-browser Verification Report

**Phase Goal:** The everyday control-center extras work end-to-end from the couch — system media and accurate absolute volume, safely double-confirmed power actions, PowerPoint-standard slide driving with a timer, and browser control via key macros.

**Verified:** 2026-07-11T06:38:28Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

Every code, wire-contract, and test layer that the five success criteria depend
on is present, substantive, wired, and behaviorally green. Because this phase
controls real Windows audio, power state, PowerPoint, and browsers, the ultimate
observable of each SC ("the PC actually obeys from the couch") requires on-device
confirmation — those items are routed to human verification, not marked as gaps.

### Observable Truths

| # | Truth (Success Criterion) | Status | Evidence |
|---|---------------------------|--------|----------|
| 1 | SC1 — media transport system-wide + absolute volume + PC-side push follow | ✓ VERIFIED (code) / ⧗ on-device | Server: `WinMedia` routes MediaPlayPause/Next/Prev via input thread, `media_key_codes_covered` green; `run_audio_thread` does absolute `SetMasterVolumeLevelScalar` with lossless 0..=100 round-trip (`pct_scalar_round_trip_is_lossless` green), 250ms poll re-acquires endpoint (Pitfall 6). Push: 4 `vol_` integration tests green (pre-auth silence, after-auth snapshot both paths, push-on-change). Client: `VolumeSliderPolicy` finger-wins/throttle/drop-unauthed (13 tests green), `MediaScreen` sends prev/playpause/next + setvol/mute. |
| 2 | SC2 — lock/sleep after slide-to-confirm; sleep SUSPENDS not hibernates | ✓ VERIFIED (code) / ⧗ on-device | `ConfirmTrackFsm` gates every send behind a ≥0.9 slide (18 tests); router `power`→`confirm` double-gate tested; `WinPower.sleep` calls `SetSuspendState(false, false, false)` (hibernate=false ⇒ suspend), every method `thread::spawn`s (Pitfall 4). |
| 3 | SC3 — restart/shutdown require slide + server confirm; no single-action path | ✓ VERIFIED (code) / ⧗ on-device | FSM emits `[SendPower, OpenCountdown]` for the destructive pair — structurally NO `SendConfirm`; `ConfirmMsg` sent from exactly 2 sites (lock/sleep effect + dialog button), `PowerMsg` from 1 site. Router: `power_alone_never_calls_power_trait`, mismatch/expiry/no-pending all err (green). `WinPower` uses `EWX_REBOOT`/`EWX_POWEROFF` + `EWX_FORCEIFHUNG` only. |
| 4 | SC4 — presenter drives slides (next/prev/start/end/blank) + elapsed timer | ✓ VERIFIED (code) / ⧗ on-device | `present_macro` table maps all 5 actions → Right/Left/F5/Esc/B (`present_macro_table_maps_every_action` green); `PresenterScreen` sends 6 `PresentMsg`; `PresenterTimer` pure FSM start/pause/resume/reset over injected clock (6 tests green); `WakelockPlus.enable`/`disable` paired. |
| 5 | SC5 — browser controls act on focused browser (incl. zoom) | ✓ VERIFIED (code) / ⧗ on-device | `browser_macro` table maps all 7 actions (`browser_macro_table_maps_every_action` green); `kBrowserActions` pins the 7 exact router strings (back/forward/newtab/closetab/refresh/zoomin/zoomout), byte-matched in `browser_screen_test`. |

**Score:** 5/5 success-criteria code layers verified. On-device physical confirmation pending (human_needed).

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `protocol/fixtures/volume/*.json` (3) | vol.changed golden fixtures incl. missing-muted hard error | ✓ VERIFIED | Fixture 03 expects `{"error": true}`; `codec_fixtures_volume` + Dart "volume fixtures" group green |
| `protocol/schema/messages.schema.json` | volChanged $defs, both fields required | ✓ VERIFIED | value 0-100 int + muted bool, t-dispatch hook present |
| `server/server-core/src/codec/json.rs` | Msg::VolChanged + payload | ✓ VERIFIED | Decode/encode arms; fixtures round-trip byte-identical |
| `server/server-core/src/dispatch/router.rs` | VolChanged in S→C ignore arm; media/browser/present tables; power gate | ✓ VERIFIED | VolChanged grouped with Pong/Err (no executor); double-confirm gate + macro tables all tested |
| `server/server-core/src/transport/mod.rs` | VolumeState + ServerDeps.volume | ✓ VERIFIED | Zero OS deps; watch receiver seam |
| `server/server-core/src/transport/session.rs` | volume_alive gated branch + after-auth snapshot + SERVER_PROTO_VERSION 1.1 | ✓ VERIFIED | Authed guard + was_authed snapshot; version "1.1" |
| `server/server-core/tests/integration.rs` | vol_ push-gating tests | ✓ VERIFIED | 4 vol_ tests green |
| `server/server-windows/src/audio_thread.rs` | run_audio_thread COM poll + pure helpers | ✓ VERIFIED | 185 lines; no unwrap/expect on COM; helpers unit-tested |
| `server/server-windows/src/executors/media.rs` | WinMedia (input_tx + audio_tx) | ✓ VERIFIED | Send-and-forget, no COM on caller |
| `server/server-windows/src/executors/power.rs` | WinPower + enable_shutdown_privilege | ✓ VERIFIED | SetSuspendState suspend, EWX_POWEROFF/REBOOT, ERROR_NOT_ALL_ASSIGNED check, 4 thread-spawns |
| `server/server-windows/src/executors/keymap.rs` | MEDIA_KEY_CODES + arms + coverage | ✓ VERIFIED | 3 arms to enigo Key::Media*, `media_key_codes_covered` green |
| `server/server-windows/src/main.rs` | audio thread spawned, real executors wired | ✓ VERIFIED | Real watch::channel, WinMedia/WinPower, no _volume_tx/StubMedia/StubPower |
| `app/.../hub/hub_screen.dart` | 5-tile registry, Trackpad primary | ✓ VERIFIED | Order Trackpad, Media, Power, Presenter, Browser |
| `app/.../screens/device_list_screen.dart` | _openHub, no TrackpadScreen | ✓ VERIFIED | _openHub ×3 (def + 2 sites); 0 non-comment TrackpadScreen refs |
| `app/.../browser/browser_screen.dart` | kBrowserActions 7 strings | ✓ VERIFIED | All 7 router strings present |
| `app/.../presenter/presenter_timer.dart` | pure clock-injected FSM | ✓ VERIFIED | No Flutter imports; 6 tests |
| `app/.../presenter/presenter_screen.dart` | zones + bar + timer + wakelock | ✓ VERIFIED | PresentMsg ×6, wakelock pair |
| `app/.../power/confirm_track_fsm.dart` | slide-to-confirm FSM | ✓ VERIFIED | 18 tests; no SendConfirm for destructive pair |
| `app/.../power/power_screen.dart` | 4 tracks + countdown dialog | ✓ VERIFIED | ConfirmMsg 2 sites, PowerMsg 1 site |
| `app/.../media/volume_store.dart` | VolumeSliderPolicy + notifier | ✓ VERIFIED | kSetvolThrottleMs ×4; 13 policy tests |
| `app/.../media/media_screen.dart` | transport + volume block | ✓ VERIFIED | prev/playpause/next + setvol/mute |
| `app/.../net/connection_service.dart` | VolChangedMsg branch + VolumeSnapshot | ✓ VERIFIED | Value-equal snapshot (==/hashCode); branch in _onFrame |

### Key Link Verification

| From | To | Via | Status |
|------|----|----|--------|
| WinMedia.play_pause | input thread | Cmd::KeyTap(MediaPlayPause) | ✓ WIRED |
| WinMedia.set_volume | audio thread | AudioCmd::SetVol(pct) | ✓ WIRED |
| audio_thread | ServerDeps.volume seam | watch::Sender<VolumeState> | ✓ WIRED |
| main.rs | audio thread + executors | run_audio_thread spawn + WinMedia/WinPower | ✓ WIRED |
| session.rs volume branch | session write path | encode_msg(Msg::VolChanged) | ✓ WIRED |
| device_list | HubScreen | _openHub at both sites | ✓ WIRED |
| power FSM effects | ConnectionService.sendReliable | PowerMsg/ConfirmMsg | ✓ WIRED |
| power dialog confirm | ConfirmMsg | sole confirm sender for restart/shutdown | ✓ WIRED |
| connection_service _onFrame | volume store | VolChangedMsg → VolumeSnapshot → changes | ✓ WIRED |
| volume_store | sendReliable | throttled MediaMsg(setvol) | ✓ WIRED |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full Rust workspace suite | `cargo test --workspace` | server-core 91 unit + 5 fixtures + 14 integration; server-windows 13 | ✓ PASS |
| vol.changed contract (both codecs) | `codec_fixtures_volume` / Dart "volume fixtures" | all scenarios incl. missing-muted hard error | ✓ PASS |
| vol_ push gating | integration `vol_*` | 4/4 pass (pre-auth silence, both snapshots, push-on-change) | ✓ PASS |
| media key coverage + pct round-trip | `media_key_codes_covered`, `pct_scalar_round_trip_is_lossless` | pass | ✓ PASS |
| power double-confirm gate | router power/confirm tests | pass (alone/mismatch/expiry/no-pending) | ✓ PASS |
| present + browser macro tables | router macro tests | pass (all actions) | ✓ PASS |
| Flutter app suite | `flutter test` (remote_control) | 280 tests pass | ✓ PASS |
| Flutter protocol suite | `flutter test` (remote_protocol) | 9 tests pass incl. volume fixtures | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| MED-01 | 05-05, 05-07 | play/pause, next, previous system-wide | ✓ SATISFIED (code) / human on-device | WinMedia media keys + client transport row; `media_key_codes_covered` green. Note: REQUIREMENTS.md traceability still marks MED-01 "Pending" (doc-sync lag — code is complete) |
| MED-02 | 05-01/03/05/07 | absolute volume via slider + server push | ✓ SATISFIED (code) / human on-device | Full wire+push+policy chain, vol_ suite + 13 policy tests green |
| PWR-01 | 05-05, 05-06 | lock behind slide-to-confirm | ✓ SATISFIED (code) / human on-device | ConfirmTrackFsm + WinPower.lock + router gate |
| PWR-02 | 05-05, 05-06 | sleep (SetSuspendState) behind slide | ✓ SATISFIED (code) / human on-device | SetSuspendState(false,..) verified in source |
| PWR-03 | 05-05, 05-06 | restart/shutdown slide + server confirm | ✓ SATISFIED (code) / human on-device | No single-action path (FSM-proven), EWX_REBOOT/POWEROFF, double-gate |
| PRES-01 | 05-04 | drive slides next/prev/start/end/blank | ✓ SATISFIED (code) / human on-device | present_macro table + PresentMsg ×6 |
| PRES-02 | 05-04 | elapsed presentation timer | ✓ SATISFIED | PresenterTimer FSM, 6 tests green (fully automatable) |
| BROW-01 | 05-02 | browser controls (key macros) | ✓ SATISFIED (code) / human on-device | browser_macro table + kBrowserActions 7 strings |

All 8 phase requirement IDs are accounted for and implemented. No orphaned requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | No TODO/FIXME/XXX/HACK/PLACEHOLDER in any phase-modified file | ℹ️ Info | Clean |
| server/server-windows/src/executors/stubs.rs | — | StubApps/StubClipboard remain | ℹ️ Info | INTENTIONAL — Phase 6 scope, not this phase's requirements; StubMedia/StubPower correctly removed |

### Notes / Warnings

- ⚠️ **Doc-sync lag:** `.planning/REQUIREMENTS.md` still lists `MED-01` as `[ ]` unchecked and its traceability row as "Pending", while all other Phase 5 IDs are "Complete". The MED-01 implementation is verified present and wired (media transport keys via the input thread, client transport buttons). This is a documentation-status lag, not a code gap — recommend ticking MED-01 to Complete during phase close.

### Human Verification Required

See frontmatter `human_verification` — 6 on-device checks mapping SC1–SC5 (the 05-VALIDATION Manual-Only table). These are inherent hardware/OS/app-integration observables (real WASAPI volume follow, SetSuspendState suspend-vs-hibernate, actual reboot/poweroff, focused PowerPoint slide driving, focused-browser macros + zoom chord) that cannot be exercised in CI. All code, wiring, and unit/integration layers beneath them are VERIFIED and green.

### Gaps Summary

No gaps. Every must-have (roadmap SC + plan frontmatter truths + declared artifacts + key links) is present, substantive, wired, and backed by passing unit/integration/fixture tests. The full Rust workspace (123 tests) and both Flutter suites (280 + 9) are green. The only outstanding dimension is on-device physical confirmation of the five success criteria, which is genuinely human-verification work — status is therefore `human_needed`, not `passed`.

---

_Verified: 2026-07-11T06:38:28Z_
_Verifier: Claude (gsd-verifier)_
