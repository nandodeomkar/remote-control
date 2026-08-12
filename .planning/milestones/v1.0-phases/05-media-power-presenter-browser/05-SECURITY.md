---
phase: 05
slug: media-power-presenter-browser
status: pass
threats_open: 0
asvs_level: 1
created: 2026-07-11
---

# Phase 05 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.
> Verify-mitigations audit (register authored at plan time, complete). Each
> `mitigate` threat confirmed present in code by grep/read; each `accept`
> threat confirmed reasonable against implementation reality.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| client `power`+`confirm` frames → OS destructive action | Authed two-step gesture drives `LockWorkStation`/`SetSuspendState`/`ExitWindowsEx` via Win32 | lock/sleep/restart/shutdown intent (irreversible, high impact) |
| client `media {setvol}` frame → absolute audio endpoint | Authed absolute-percent write to the default WASAPI render endpoint (`IAudioEndpointVolume`) | volume 0..100 (device state) |
| server volume state → authed client push | Host `vol.changed` (S→C, protoVersion 1.1) reflects live PC audio state back to the phone | volume/mute state (host state — info disclosure if unauthed) |
| client `browser`/`present` frames → OS keystroke macros | Authed nav/presenter chords become real `key_tap` into the focused window | benign key chords (Ctrl+T/W, F5, arrows, Esc, B) |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Evidence | Status |
|-----------|----------|-----------|-------------|----------|--------|
| T-05-01 | Tampering (input validation) | `vol.changed` decode, both codecs | mitigate | Rust: `VolChangedPayload { value: u64, muted: bool }` both non-Option → required; missing → `CodecError::MissingField` hard error (json.rs:143-147, 349-359). Dart: `VolChangedMsg.fromPayload` `_req<int>('value')` + `_req<bool>('muted')` throw `FormatException` (json_codec.dart:390-391). Negative fixture `03-vol-changed-missing-muted.json` `expect.error=true` | closed |
| T-05-02 | Spoofing | router.rs `route()` | mitigate | `Msg::VolChanged(_)` sits in the S→C-only ignore arm → `Vec::new()`; no executor call, no reply (router.rs:250-259) | closed |
| T-05-05 | Information Disclosure | session.rs volume `select!` branch | mitigate | Push branch guard `volume_alive && ctx.auth_state == AuthState::Authed` (session.rs:159); after-auth snapshot fires only at the Authed transition (session.rs:223); regression test `vol_no_push_preauth` asserts silence pre-auth, snapshot post-pair (integration.rs:699-725) | closed |
| T-05-06 | Denial of Service | volume push channel | mitigate | `watch::Receiver<VolumeState>` is latest-value-only (no backlog to flood); frames ride the bounded `mpsc::channel(64)` write queue (session.rs:92); `Err(_) => volume_alive = false` disables the branch, no busy-loop (session.rs:170) | closed |
| T-05-07 | EoP | present macros on focused window | accept | `present_macro` yields modifier-free keys tapped with `&[]` (router.rs:227-232, 325-335); reachable only behind the auth gate (router.rs:67) + pause gate (router.rs:75). Risk AR-05-01 | closed |
| T-05-08a | DoS (client) | wakelock + 1s timer | mitigate | `WakelockPlus.enable()` in initState, `WakelockPlus.disable()` in dispose (presenter_screen.dart:88, 94); `_ticker` cancelled in dispose (presenter_screen.dart:93); countdown dialog 1s timer cancelled in dispose (power_screen.dart:449-452) | closed |
| T-05-08b | EoP | power.rs `enable_shutdown_privilege` | mitigate | `SE_SHUTDOWN_NAME` is the only privilege looked up (power.rs:49); `ERROR_NOT_ALL_ASSIGNED` checked before returning — `adjusted && fully_assigned` (power.rs:62-67); a silent partial grant is treated as failure | closed |
| T-05-09 | DoS (self) | blocking Win32/COM | mitigate | Every `Power` method `std::thread::spawn`s (power.rs:99, 107, 120, 126); COM/WASAPI live only on the dedicated audio thread with `recv_timeout(250ms)` (audio_thread.rs:130, 140); `WinMedia` sends non-blocking on mpsc (media.rs) | closed |
| T-05-10 | Tampering (data loss) | `ExitWindowsEx` flags | mitigate | `do_exit` uses `flags \| EWX_FORCEIFHUNG` only (power.rs:88-91); `EWX_FORCE` is never imported (power.rs:18-21) or used; non-zero planned reason `SHTDN_REASON_MAJOR_OTHER \| SHTDN_REASON_MINOR_OTHER \| SHTDN_REASON_FLAG_PLANNED` (power.rs:90) | closed |
| T-05-11 | EoP | single-message power path | mitigate | `exec.power.*` is reachable only from the `Confirm` arm's matched-and-in-window branch (router.rs:169-192) behind the `power`→`confirm` 10s single-shot gate (`CONFIRM_WINDOW` router.rs:26; `take()` single-shot router.rs:173); power.rs adds no new call path into the `Power` trait (header + 05-05 Threat Flags) | closed |
| T-05-12 | EoP (single-action path) | power_screen effect wiring | mitigate | `PowerMsg` sent only from the `SendPower` effect (power_screen.dart:139-140), emitted only for a completed ≥0.9 slide (confirm_track_fsm.dart:143-150); destructive pair emits `OpenCountdown`, never `SendConfirm` (confirm_track_fsm.dart:149); restart/shutdown `ConfirmMsg` only from the dialog button (power_screen.dart:165); server 10s gate authoritative | closed |
| T-05-13 | Repudiation / accidental | ConfirmTrackFsm threshold | mitigate | `kConfirmCompletionThreshold = 0.9` (confirm_track_fsm.dart:37); below threshold → `SpringBack`, nothing sent (confirm_track_fsm.dart:153-155); tracks inert when disconnected — all drag handlers early-return `if (!widget.enabled)` with `enabled = authed` (power_screen.dart:177, 281, 290, 297) | closed |
| T-05-14 | DoS (stale confirm replay) | countdown dialog | accept | `take()` clears pending on any confirm incl. mismatch (router.rs:173); `CONFIRM_WINDOW` 10s expiry (router.rs:175); late confirm → `err{noPendingAction}` (router.rs:187-190), client silently ignores (power_screen.dart:27-33). Risk AR-05-02 | closed |
| T-05-03 | EoP | browser macros on focused window | accept | `browser_macro` maps to benign nav chords (Ctrl+T/W, F5, Ctrl+Plus/Minus, BrowserBack/Forward) behind auth+pause gates (router.rs:221-226, 310-322). Risk AR-05-03 | closed |
| T-05-04 | DoS | `sendReliable` flood | accept | Bounded reliable FIFO `maxQueue = 10`; overflow drops with `onOverflow` (send_policy.dart:34, 47-52); router dispatch is an O(1) `match` (router.rs:80-259). Risk AR-05-04 | closed |
| T-05-15 | DoS | setvol flood | mitigate | `kSetvolThrottleMs = 50` leading-edge throttle (volume_store.dart:37, 108-111); sends ride the bounded FIFO ≤10 (send_policy.dart:34); router drops `setvol > 100` via `.filter(\|v\| *v <= 100)` (router.rs:151-154) | closed |
| T-05-16 | Tampering (stale replay) | reliable queue during blip | mitigate | Policy DROPS (never queues) `setvol` while unauthed — `if (!isAuthed()) return;` in both `dragUpdate` and `dragEnd` (volume_store.dart:106, 120); volume is continuous state, not a replayable command | closed |
| T-05-17 | Spoofing (client trust of push) | `VolChangedMsg` branch | accept | `VolChangedMsg` processed only inside the authed session read path (connection_service.dart:462-468); values clamped 0..100 on ingest — `onPush` → `_clamp` (volume_store.dart:84-89, 132). Risk AR-05-05 | closed |
| T-05-SC | Supply Chain | package installs | accept | No new packages in any 05-0x plan (SUMMARY threat surfaces confirm); `wakelock_plus` is already spec-locked (CLAUDE.md stack). Risk AR-05-06 | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-05-01 | T-05-07 | Presenter macros are modifier-free benign keys (arrows, F5, Esc, B) tapped into the focused window; reachable only behind the existing auth + pause gates. No privileged surface beyond ordinary keystroke injection already accepted in Phase 04 | owner (plan-time disposition) | 2026-07-11 |
| AR-05-02 | T-05-14 | A replayed/late `confirm` cannot act: the server single-shot `take()` clears pending on any confirm and the 10s window expires; a stale confirm earns `err{noPendingAction}` and is silently ignored by the client. Low blast radius, no new state | owner (plan-time disposition) | 2026-07-11 |
| AR-05-03 | T-05-03 | Browser macros are benign navigation chords (new/close tab, refresh, back/forward, zoom) into the focused window behind auth+pause gates — same keystroke-injection trust boundary already accepted in Phase 04 | owner (plan-time disposition) | 2026-07-11 |
| AR-05-04 | T-05-04 | A `sendReliable` burst is bounded by the ≤10 FIFO (overflow drops, no unbounded growth) and each frame routes through an O(1) server match; no amplification path | owner (plan-time disposition) | 2026-07-11 |
| AR-05-05 | T-05-17 | The client trusts `vol.changed` only over the authed WS session, and clamps incoming values into 0..100 before use — a hostile/garbled push cannot drive the slider out of range or forge state on an unauthed channel | owner (plan-time disposition) | 2026-07-11 |
| AR-05-06 | T-05-SC | No new dependencies added this phase; `wakelock_plus` (the only device-capability lib touched) is already vetted and spec-locked in the project stack. No supply-chain delta | owner (plan-time disposition) | 2026-07-11 |

*Accepted risks do not resurface in future audit runs.*

---

## Unregistered Flags (audit 2026-07-11 — no threat-register mapping)

None. Every entry in the SUMMARY threat-surface sections (05-04 Threat Surface, 05-05 Threat Flags, 05-06/05-07 Threat Surface) maps to a registered threat ID. Plans 05-01/05-02/05-03 introduced no new attack surface — their documented deviations are protocol-version-literal bumps (`clientProtoVersion`, beacon fixture `proto`) and a `ServerDeps.volume` compiler-ripple wiring, none of which add an entry point, auth path, or trust boundary.

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-11 | 19 | 19 | 0 | gsd-security-auditor |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Every `mitigate` threat confirmed present in code (file:line evidence above)
- [x] Every `accept` threat confirmed reasonable against implementation reality
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed — all 13 mitigate + 6 accept threats closed
- [x] Implementation files unmodified (audit is read-only)

**Approval:** SECURED — 19/19 threats closed, 0 open, no unregistered flags. `block_on: high` satisfied.
