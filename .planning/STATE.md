---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Ready to execute
stopped_at: Phase 7 UI-SPEC approved
last_updated: "2026-07-12T12:05:00.000Z"
last_activity: 2026-07-12 -- Phase 07 Plan 02 complete (input.blocked proto-1.3 wire contract)
progress:
  total_phases: 7
  completed_phases: 6
  total_plans: 56
  completed_plans: 45
  percent: 80
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-11)

**Core value:** Phone controls the laptop over WiFi with zero friction: instant cursor response, full keyboard, and the control-center extras — all free.
**Current focus:** Phase 07 — server-shell-dashboard-polish

## Current Position

Phase: 07 (server-shell-dashboard-polish) — EXECUTING
Plan: 3 of 13
Next: 06-05-PLAN.md (Clipboard client: send/fetch + last-5 history + hub tile), then 06-06 (auto-sync + client echo suppression + Android 10+ resume-sync) and 06-07 (on-device UAT gate). The Clipboard server (06-04: clip thread + WinClipboard + clip.changed seam) is now code-complete alongside the Apps track (06-01/02/03); on-device UAT is 06-07.
  Phase 05 CLOSED 2026-07-11: 7/7 plans, verification 5/5 code layer, UAT 6/6 on-device (media, absolute volume+PC follow, lock/sleep-suspend, restart/shutdown two-gesture, PowerPoint presenter, browser macros incl. fixed zoom-in), security threats_open 0 (19/19). Google Slides web-start = documented known limitation (out of SC4 scope).
  Phase 03 E2E on Xiaomi 25080RABDI + Windows 11: all five success criteria passed
  (discovery ≤4s, PIN pairing + error copy, silent reconnect, WiFi-drop recovery,
  manual IP, live latency header with no hot-path hitching). See 03-VERIFICATION.md.
  Carried Phase-4 item: Windows "Enhance pointer precision" suppresses slow relative
  deltas — workaround is disabling it; absolute-injection fix (enigo Coordinate::Abs)
  is a pending todo (Phase 4 candidate).
  See: 03-VERIFICATION.md, 03-07-SUMMARY.md
Last activity: 2026-07-12 -- Phase 07 execution started

Progress: [███████░░░] 74% (5 of 7 phases complete; 41 of 43 plans)

## Performance Metrics

**Velocity:**

- Total plans completed: 22
- Average duration: -
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01 | 8 | - | - |
| 05 | 7 | - | - |
| 06 | 7 | - | - |

**Recent Trend:**

- Last 5 plans: -
- Trend: -

*Updated after each plan completion*
| Phase 01 P01 | 10min | 3 tasks | 23 files |
| Phase 01 P02 | 10min | 2 tasks | 24 files |
| Phase 01 P03 | 6min | 2 tasks | 2 files |
| Phase 01 P04 | 13min | 2 tasks | 4 files |
| Phase 01 P05 | 12min | 2 tasks | 3 files |
| Phase 01 P06 | 13min | 2 tasks | 4 files |
| Phase 01 P07 | 16min | 2 tasks | 0 files |
| Phase 01 P08 | 18min | 3 tasks | 13 files |
| Phase 02 P01 | 45min | 3 tasks | 8 files |
| Phase 02 P02 | 28min | 3 tasks | 31 files |
| Phase 02 P03 | 11min | 3 tasks | 10 files |
| Phase 02 P04 | manual | 1 task | 1 file |
| Phase 03 P02 | 8min | 2 tasks | 4 files |
| Phase 03 P03 | 8min | 2 tasks | 4 files |
| Phase 03 P01 | 15min | 3 tasks | 17 files |
| Phase 03 P04 | 11min + checkpoint | 3 tasks | 8 files |
| Phase 03 P05 | ~25min (2 sessions) | 2 tasks | 5 files |
| Phase 03 P06 | 17min | 3 tasks | 6 files |
| Phase 04 P01 | 10min | 2 tasks | 3 files |
| Phase 04 P03 | 16min | 3 tasks | 7 files |
| Phase 04 P02 | 6min | 2 tasks | 4 files |
| Phase 04 P04 | 25min (2 sessions) | 3 tasks | 6 files |
| Phase 04 P05 | 18min | 3 tasks | 6 files |
| Phase 04 P06 | 13min | 3 tasks | 8 files |
| Phase 04 P09 | 3min | 2 tasks | 2 files |
| Phase 04 P10 | 11min | 2 tasks | 2 files |
| Phase 05 P01 | 7min | 3 tasks | 14 files |
| Phase 05 P02 | 8min | 3 tasks | 5 files |
| Phase 05 P03 | 9min | 2 tasks | 6 files |
| Phase 05 P04 | 12min | 2 tasks | 4 files |
| Phase 05 P05 | 12min | 3 tasks | 8 files |
| Phase 05 P06 | ~7min | 2 tasks | 5 files |
| Phase 05 P07 | ~20min | 2 tasks | 5 files |
| Phase 06 P01 | ~20min | 3 tasks | 12 files |
| Phase 06 P02 | 25min | 3 tasks | 7 files |
| Phase 06 P03 | ~30min | 3 tasks | 8 files |
| Phase 06 P04 | ~30min | 3 tasks | 11 files |
| Phase 06 P05 | ~30min | 3 tasks | 6 files |
| Phase 07 P01 | 4min | 2 tasks | 1 files |
| Phase 07 P02 | 15min | 2 tasks | 6 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Research phases 1+2 merged into Phase 1 (protocol contract + server core — both pure foundation); control-center split into Phase 5 (thin key-macro executors) and Phase 6 (fiddly push-driven Apps/Clipboard)
- [Roadmap]: Phase 2 is a hard gate — <30ms cursor budget on real WiFi must pass before Phase 3, else transport decision (UDP channel) is revisited
- [Roadmap]: Two spec amendments from research are wire-format decisions settled in Phase 1: challenge-response auth (HMAC-SHA256 of server nonce) and diff-ops text messages (IME-safe)
- [Roadmap]: REQUIREMENTS.md said "36 total" but contains 38 REQ-IDs; coverage corrected to 38/38
- [Phase ?]: Auth construction locked: HMAC key = SHA-256(raw token), message = nonce bytes — verifiable from stored hash; fixes design spec §4 unimplementable literal text
- [Phase ?]: 05-auth-proof.json macHex computed by independent .NET crypto — cross-language byte-identity anchor for Rust and Dart codecs
- [Phase ?]: Nonfinite binary fixture uses canonical quiet NaN bits 0x7fc00000 per plan (not .NET's negative-NaN variant)
- [Phase 01]: Enum-valued wire fields (button/action/reason) are plain Strings in codec payload structs: codec stays value-lenient (version-2 hello must decode), semantic validation lives in the router
- [Phase 01]: Canonical-form serde attributes (skip_serializing_if on every Option field) locked in Wave 2 so Plan 03 encode round-trip needs no struct changes
- [Phase 01]: Every todo!() body names its implementing plan (01-03..01-06) so red-test panics identify the responsible wave
- [Phase 01]: encode_msg always emits p (as {} for empty payloads): fixture expect envelopes carry p unconditionally, overriding the plan's omit-empty-p wording
- [Phase 01]: MissingField is reserved for payload-level required fields; envelope-level serde failures map to BadJson
- [Phase 01]: rand 0.10 renamed RngCore → Rng at crate root; hmac 0.13 requires explicit KeyInit import for new_from_slice (RESEARCH snippets predate these majors)
- [Phase 01]: pending_power uses tokio::time::Instant so start_paused tests drive the 10s confirm window; mismatched confirm clears the pending action (single-shot take)
- [Phase 01]: Router drops semantic-invalid values silently (bad button/action/mods, setvol > 100): SPEC defines no err code for bad enum values and inventing one creates a probing surface
- [Phase 01]: Post-auth JSON decode errors reply err{internal} and keep the connection; SPEC err table defines no decode-failure code, pre-auth decode errors stay silent per SPEC section 6
- [Phase 01]: Unparseable protoVersion major treated as versionMismatch (err + close) per D-06 reject-by-default; session FSM owns hello/pin/auth and ignores post-auth handshake replays
- [Phase 01]: Zero-Windows-deps verified against Linux target tree: windows-sys on the host tree is tokio/mio/socket2 platform plumbing only
- [Phase 02]: Default WebSocket port 17777 with RC_PORT env override (spec names no numeric default; settings UI is Phase 7)
- [Phase 02]: DEV_PIN dev shortcut not implemented — AuthManager has no fixed-PIN API and the console-printed real PIN serves the owner's test loop (T-02-EP surface never created)
- [Phase 02]: enigo::set_dpi_awareness() helper (re-exported at crate root in 0.6.1) used for DPI awareness; windows-crate fallback not needed
- [Phase 02]: Enigo injection failures on the input thread are dropped (send-and-forget hot path), never panic
- [Phase 02]: A2 resolved: ConnectionTask.fromSocket is public in Dart 3.12.2 — RESEARCH TCP_NODELAY construction used verbatim, no fallback idiom
- [Phase 02]: connectNoDelay awaits channel.ready so WebSocket connect failures surface at the call site, not only on the stream
- [Phase 02]: MoveSender.sink typed StreamSink<dynamic> so IOWebSocketChannel.sink plugs in directly; tests substitute a recording fake
- [Phase 02]: Client handshake is a pure IO-free FSM (HandshakeFsm) mirroring session.rs exactly (hello -> always challenge -> pin|auth branch on in-memory token); a thin HandshakeDriver does all channel IO — transitions proven without a socket
- [Phase 02]: Reconnect/auth path reuses authProof(hexDecode token, hexDecode nonce) verbatim — no client-side crypto invented; asserted byte-equal in the FSM test
- [Phase 02]: Latency measured round-trip-UNDER-move-load (ping every K moves OR ~250ms), not idle RTT — the faithful proxy for ack-less move frames (D-06); nearest-rank percentile (rank = ceil(p/100*N), clamped)
- [Phase 02]: Single channel-stream listener decodes each frame once and routes handshake -> driver, pong -> probe (no double-subscribe); hot move path never rebuilds the HUD (timer-polled on a throttle)
- [Phase 02]: ws:// LAN needs AndroidManifest INTERNET permission + usesCleartextTraffic=true; scoped network-security-config deferred to Phase 3
- [Phase 02]: Hard gate judged PASS with the pointer-accel workaround (Windows "Enhance pointer precision" disabled): the suppressed slow deltas are OS-injection fidelity downstream of the correct sub-pixel accumulator, not transport/latency — absolute-injection fix (enigo Coordinate::Abs) deferred to a pending todo (Phase 4 candidate)
- [Phase 03-02]: Backoff cap is 10s (design spec §8) over D-06 discretionary ~30s; delay = base(1/2/4/8/10s) x (0.8 + 0.4*random()) rounded to ms, injectable random for deterministic tests
- [Phase 03-02]: authRejected for ANY reason lands in needPairing with AuthStopEffect + CloseEffect and never a retry; ClearTokenEffect + revoked explanation only for noPairing/badMac
- [Phase 03-02]: beaconSighted short-circuit also resets the attempt counter — consistent D-06 fresh-start semantics with appResumed/retryNowPressed
- [Phase 03-03]: loadDevices returns Map keyed by deviceKey; DeviceMeta.toJson excludes the key so the prefs devices JSON byte-matches RESEARCH Pattern 7
- [Phase 03-03]: SharedPrefsKv wraps SharedPreferencesAsync (2.5.x current API), thin adapter so DeviceStore never sees the API choice
- [Phase 03-03]: Every SecureKv read/delete is Pitfall-5-wrapped (deleteToken swallows PlatformException like reads); writes stay raw so pairing save failures surface
- [Phase 03-01]: SERVER_PROTO_VERSION widened to pub(crate) and referenced by encode_beacon — proto literal never duplicated
- [Phase 03-01]: MachineGuid registry-read failure degrades to stable "name-<device_name>" id with a warn — identity failure never crashes the server
- [Phase 03-01]: if-addrs in server-core (cross-platform, preserves zero-Windows-deps); winreg + tauri-winrt-notification isolated in server-windows; toast attributed to "Windows PowerShell" is the accepted v1 quirk (AUMID lands with Phase-7 tray)
- [Phase 03-04]: Beacon.host is always the datagram source address — payload fields can never redirect where the client dials (T-03-13 spoof containment)
- [Phase 03-04]: BeaconListener pairs MulticastLock with the socket lifecycle: acquire before bind, release on stop AND bind failure (retryable); broadcast stream survives stop/start
- [Phase 03-04]: MulticastLock MethodChannel no-ops on MissingPluginException — OEM insurance, not a requirement; tests and non-Android hosts need no fakes
- [Phase 03-04]: network_security_config.xml keeps base-config cleartext (Android XML has no CIDR scoping); real LAN-only enforcement is the ConnectionService RFC1918 guard in 03-05 (D-10 split documented in-file)
- [Phase 03-05]: Liveness is a generation-guarded tick chain on the injected schedule seam (no Timer.periodic) — probe stays timer-free, tests deterministic; probe.reset() keeps the RTT window so the header shows last-known latency through teardown
- [Phase 03-05]: Guard refusal (non-RFC1918 dial) is a terminal user-input error -> idle with lastDialError; transportFailed is reserved for real transport blips (backoff would hammer a public host)
- [Phase 03-05]: Reliable queue survives transport blips (teardown drops only volatile gating); AuthStopEffect is the sole queue-clearing path — a revoked target re-pairs before anything flushes
- [Phase 03-05]: ConnectionStatus snapshot is value-equal (== / hashCode) so the Riverpod Notifier suppresses no-op rebuilds on changes pings; D-10 enforcement split now COMPLETE (XML + code guard both shipped)
- [Phase 03-06]: DeviceListEntry equality excludes lastSeenMillis: anti-churn falls out of listEquals — unchanged beacons publish nothing, rows never blink per packet
- [Phase 03-06]: Pairing sheet rebuilds via StreamBuilder over service.changes — needPin/failure transitions never alter the value-equal ConnectionStatus snapshot, so a provider watch alone would miss them
- [Phase 03-06]: Post-authFail retry is one tap: the sheet stores the PIN as pending, fires a fresh connectTo, and auto-feeds it when the new handshake reaches needPin
- [Phase 03-06]: Firewall-blocked copy requires BOTH a failed manual dial AND a currently-live beacon row at that host; otherwise the generic transport copy with ip:port renders
- [Phase 03-07]: Header chip + banner poll their own Timer.periodic(kHudReadThrottle 500ms) — decoupled from the hot move path (Pitfall 9); the single latency/status surface for every connected-capable screen
- [Phase 03-07]: attachBeacons wired into DeviceListNotifier so the D-06 beacon short-circuit is live end-to-end (03-05's attachBeacons had no caller otherwise); trackpad hint strings centralized in connection_copy.dart
- [Phase 03-07]: D-01 launch kick runs post-first-frame in DeviceListScreen initState — silent reconnect to lastDeviceKey, NO nav on success (user stays on the list); explicit row-tap is the only path that navigates to the trackpad
- [Phase 04-03]: ScrollIntent carries delta/2 per move event (per-event average of the two pointers' deltas); fling velocity = in-window sample sum / (lift - oldest sample ts) so a pause naturally cancels the fling
- [Phase 04-03]: Drag-lock edges: onLongPressFire while locked is a no-op, onPointerCancel keeps the lock (only reset() or tap-to-drop clears), second finger during a drag is ignored
- [Phase 04-03]: Pre-slop pointer travel (<=kTapSlopPx) emits nothing — tap candidate preserved, <=10px startup motion intentionally dropped (standard trackpad behavior)
- [Phase 04-02]: Open Q3 resolved: terse key.code vocabulary locked in keymap.rs CLIENT_KEY_CODES (Esc/Tab/Home/End/PgUp/PgDn/Del, Up/Down/Left/Right, F1..F12, Num0..Num9 + NumEnter + NumDot, ControlLeft/AltLeft/ShiftLeft/WinLeft) — 04-06 kClientKeyCodes must mirror byte-for-byte
- [Phase 04-02]: Router Phase-1 browser/present macro codes (BrowserBack/BrowserForward/T/W/B/Plus/Minus) mapped in map_key via Key::Unicode so already-routed actions execute instead of silently no-opping
- [Phase 04-02]: KeyTap with an unknown code drops the WHOLE command — modifiers never pressed around a key that will not fire; Cmd dropped Copy (heap-owning variants, mpsc send moves)
- [Phase 04-04]: Long-press verdicts round-trip through the classifier (onLongPressElapsed -> onLongPressFire -> driver.handle) so drag-start vs stale-fire logic stays in the pure FSM
- [Phase 04-04]: D-05 sensitivity bridged to the hot path via ref.listenManual(fireImmediately) updating a cached double — never a per-event provider lookup; store clamps read+write and degrades to default on platform read failure
- [Phase 04-04]: Tune sheet is a Consumer-scoped modal route outside the Listener subtree — tuning never rebuilds the trackpad surface or header chip
- [Phase ?]: 04-05: IME-revision diff follows fixture 02 / computeDiff semantics (bs:1, ins:'e ') — plan's bs:3 expectation was a typo; computeDiff stays the only diff engine
- [Phase ?]: 04-05: hidden IME field rides a ZWSP sentinel (8 x U+200B) so boundary backspaces keep emitting bs frames; HiddenTextInput mounted OUTSIDE the panel's AnimatedSize so toggling never detaches the input connection
- [Phase 04-06]: LOCKED modifier = physical hold via keymap.rs hold codes (KeyMsg down/up) excluded from modsForTap (Pitfall 7 double-apply avoidance); ARMED rides the mods array of the next non-modifier tap only, then auto-resets
- [Phase 04-06]: D-12: ModifierFsm.disconnected() resets with ZERO effects and the panel forgets its held key cap — CONN-07 release_all already freed real keys; a queued stale up must never flush into a NEW session
- [Phase 04-06]: keyboard.rowGroup store rides the PrefsKv seam (device_store pattern) instead of raw SharedPreferencesAsync — its constructor throws StateError in tests without a platform instance
- [Phase 04]: 04-09: Phase-04-03 scroll decision refined: ScrollIntent carries delta/n over LIVE tracked pointers (n=2 both fingers down — byte-identical averaging; n=1 after a lift = full rate, WR-04 closed); no new tuning constant, classifier stays pure FSM
- [Phase 04-10]: Liveness deadline via sleep_until(last_inbound + LIVENESS_TIMEOUT 10s) select! branch in run_session — expiry breaks 'read onto the EXISTING CONN-07 cleanup; last_inbound refreshes on ANY inbound frame (Text/Binary/WS control), never on pause toggles
- [Phase 04-10]: Half-open socket tests keep the client alive and silent (drop/close emits FIN/RST on loopback); paused clock for the deadline wait, tokio::time::resume() before real-IO session-end assertions (auto-advance races kernel FIN)
- [Phase 05-01]: VolChangedPayload uses u64 value + bool muted with NO Option — serde missing-field is the hard decode error fixture 03 demands
- [Phase 05-01]: clientProtoVersion in handshake_fsm.dart references the remote_protocol protoVersion constant so minor bumps cannot leave a stale lib literal; remaining '1.0' test literals are commented historical wire pins (Pitfall 10)
- [Phase ?]: 05-02: Browser grid rows derive from kBrowserActions with a data-driven pairing rule (refresh full-width) — the 7-action list stays the single source of truth vs router.rs
- [Phase ?]: 05-02: kHubTiles ordered registry IS the hub render order (Trackpad first, full-width primary); later plans insert HubTileSpec entries with zero grid changes
- [Phase ?]: 05-02: Hub tiles + browser keys fire callbacks on tap-down via the MouseButtonsBar house pattern — widget tests never touch the Navigator or a service fake
- [Phase 05-04]: PresenterTimer is a pure clock-injected FSM (stopped/running/paused) over nowMillis — elapsed excludes paused gaps (accumulated + live span while running); startShow resets from ANY state; no timers/IO/Flutter in the FSM (D-08, Pitfall 13)
- [Phase 05-04]: The presenter mm:ss ticker is a widget-local 1s Timer.periodic created LAZILY on first Start show (no rebuild loop before a show) and cancelled in dispose; the timer text tap/long-press stays interactive even when disconnected because the elapsed clock is strictly client-local (D-08)
- [Phase 05-04]: PresenterScreen gates only the present-sending controls (zones, Start/End/Blank) on auth (muted, never red); Blank is optimistic local state (no wire readback) rendered with the armed-chip outline; WakelockPlus scoped initState->dispose (D-09); Presenter tile inserted between Trackpad and Browser in kHubTiles
- [Phase 05-05]: First COM usage in the repo — dedicated audio thread owns the apartment (CoInitializeEx MTA), re-acquires MMDeviceEnumerator→default endpoint→IAudioEndpointVolume FRESH every 250ms pass so default-device switches survive with zero notification plumbing (Pitfall 6); every HRESULT `.ok()?`-drops, never unwraps
- [Phase 05-05]: IMMDevice::Activate is feature-gated on Win32_System_Com_StructuredStorage + Win32_System_Variant (PROPVARIANT param) beyond the 7 RESEARCH-listed windows features — cargo surfaced both (A3)
- [Phase 05-05]: enable_shutdown_privilege() checks GetLastError() != ERROR_NOT_ALL_ASSIGNED so a silent partial grant is failure (Pitfall 1); every WinPower method thread::spawns (SetSuspendState may block until resume — never a tokio worker, Pitfall 4); sleep=SetSuspendState(false)=SUSPEND not hibernate (SC2); shutdown=EWX_POWEROFF|EWX_FORCEIFHUNG + non-zero planned dwReason (never the unconditional force flag — data loss)
- [Phase 05-05]: WinMedia holds only two senders (input_tx media taps MED-01, audio_tx volume MED-02) — send-and-forget, no COM on the caller (Pitfall 5); pct_from_scalar rounds+clamps for a lossless 0..=100 round trip (Pitfall 7); StubMedia/StubPower gone, only StubApps/StubClipboard remain for Phase 6
- [Phase 05-06]: ConfirmTrackFsm is a pure per-track slide-to-confirm FSM (idle→dragging(progress)→completed) — sealed effects (SendPower/SendConfirm/OpenCountdown/SpringBack) carry only the action string, no Flutter/IO/timers/wire types; 0.9 completion threshold, spring-back below (T-05-13)
- [Phase 05-06]: The single-action-path gate (T-05-12/PWR-03) is structural: SendPower is always effect[0], a single `if (isDestructive)` picks the second effect, so the FSM can never emit SendConfirm for restart/shutdown — unit-proven; PowerMsg is sent from exactly one screen site, ConfirmMsg from exactly two (lock/sleep effect + dialog button)
- [Phase 05-06]: D-05 lock/sleep completion sends power+confirm same-tick (FIFO held by the reliable queue); D-06 restart/shutdown open the app's ONE modal — a red countdown dialog with a dialog-local 1s ticker seeded from kPowerConfirmWindowSeconds=10 (server CONFIRM_WINDOW mirror); auto-dismiss at 0 / Cancel / barrier send nothing, late confirm's err{noPendingAction} silently ignored, post-confirm disconnect is banner-only (RESEARCH Pattern 5)
- [Phase 05-06]: Power hub tile (Icons.power_settings_new) inserted between Trackpad and Presenter → order Trackpad, Power, Presenter, Browser; the bare-grid hub test surface was enlarged to 800x1400 for the 4th tile (production HubScreen scrolls the grid)
- [Phase 05-07]: VolumeSliderPolicy is a pure clock-injected D-04 finger-wins policy — leading-edge kSetvolThrottleMs=50 throttle, dragStart resets throttle bookkeeping so each fresh drag's first update sends, dragEnd flushes final iff it differs from last sent ([10,30] no-dup / [10,30,45] throttled-tail both unit-proven), unauthed drops-never-queues (Pitfall 12); injected seams are public fields per presenter_timer convention
- [Phase 05-07]: VolChangedMsg parks a value-equal VolumeSnapshot on ConnectionService (branch after PongMsg, before driver routing, no payload logged) → changes ping → VolumeNotifier (cloned from ConnectionStatusNotifier); Media screen renders slider + mute from the pushed snapshot only (mute has NO optimistic flip, follows next push); Media hub tile (Icons.music_note) inserted ahead of Power → FINAL 5-tile order Trackpad, Media, Power, Presenter, Browser (D-01 complete)
- [Phase 06-01]: WindowInfo.icon/path are additive Option<String> with serde default + skip_serializing_if (mirrors the Phase-5 1.1 vol amendment) → legacy windows still decode and re-encode without the keys, Eq derive preserved; SERVER_PROTO_VERSION 1.1→1.2 (additive minor, 1.0/1.1 clients accepted) and the shared beacon fixture proto bumped in lockstep (D-09 single source of truth)
- [Phase 06-01]: apps.changed has NO after-auth snapshot (unlike vol.changed) — the client pulls the initial list via apps.list on screen open, so the authed-gated select! branch is the SOLE apps-push site; the == AuthState::Authed guard is the T-06-01 privacy backstop (clone of the volume branch)
- [Phase 06-01]: Apps::focus/close/launch return bool → router emits err{windowGone} (focus/close) / err{launchFailed} (launch) on false, silent on true; err msg strings are operator-facing prose that NEVER embed the HWND id or exe path (T-06-12), asserted in the FailingApps router test
- [Phase 06-01]: A pending pre-auth apps watch change is delivered as the FIRST post-auth push once the authed-gated branch enables (after the D-03 vol snapshot) — used as the positive control in apps_no_push_preauth proving the pre-auth silence was the auth gate, not a dead channel
- [Phase ?]: [Phase 06-02]: Apps enumeration runs on a dedicated OS thread (audio_thread clone) — EnumWindows Z-order + 5-point Alt-Tab filter (visible/titled/tool-app/owner-root/DWM-uncloaked); pure is_alt_tab_window predicate unit-tested without OS calls; list capped 50 + push_if_changed anti-flood (APPS-03)
- [Phase ?]: [Phase 06-02]: Icon pipeline SHGetFileInfoW(by exe path, owned->DestroyIcon) with WM_GETICON/class-icon fallback(borrowed->kept) -> GetDIBits 32bpp BGRA -> RGBA -> png -> hand-rolled base64, cached by exe path; encodes the bitmap's ACTUAL dims (GetObjectW) since GetDIBits cannot rescale
- [Phase ?]: [Phase 06-02]: WinApps validates focus/close ids against the current snapshot BEFORE sending (stale id -> false -> err{windowGone}); the apps thread's own IsWindow is the second-line same-tick-recycle guard (T-06-13 accept); UWP/ApplicationFrameHost/WindowsApps paths -> path=None (non-pinnable, focus/close still work)
- [Phase 06-03]: Dart WindowInfo mirrors protocol 1.2 (optional icon/path via _opt tolerant parse + skip-none toJson + value ==); ConnectionService parks a value-equal AppsSnapshot from apps.changed AND the apps.list reply, plus _lastError from err — the err arm is parked but NOT returned early so err{versionMismatch} still reaches handshake_fsm's terminal-fail path
- [Phase 06-03]: AppsSnapshot/AppsViewState equality is hand-rolled element-wise — no package:collection dependency added (not a direct dep; T-06-SC no-new-packages held); FavoritesStore.load returns a GROWABLE list (never const []) so pin/unpin mutate in place (bug caught by the RED suite)
- [Phase 06-03]: FavoritesStore (PrefsKv key apps.favorites, non-secret D-02) pins ONLY a running window's server-resolved WindowInfo.path (T-06-04, no manual-path field), rejects UWP path==null (Flag 1), dedupes by path, corruption-tolerant; Apps screen surfaces err toasts off the raw service.changes stream (identity-tracked) because the value-equal view never rebuilds on an err park
- [Phase 06-03]: Apps hub tile (Icons.apps) inserted after Media, before Power -> order Trackpad, Media, Apps, Power, Presenter, Browser (06-UI-SPEC placement)
- [Phase 06-04]: clip.changed has NO after-auth snapshot AND no unconditional snapshot analog (volume drains one even at default) — the PC clipboard is never dumped implicitly; a freshly-authed phone gets nothing until a real external change, pulling current value via clip.get (Pitfall 8 / T-06-05). Tested by leaving the watch at default and asserting silence (contrast with the drained vol snapshot)
- [Phase 06-04]: ClipCmd::Set NEVER pushes to the watch — the clip thread writes arboard + records the set fingerprint, and the next poll's read-back is echo-suppressed when its sha2 fingerprint matches (Pitfall 5, D-05). Consequence (plan-mandated): WinClipboard::get() returns the last EXTERNAL mirrored value, not the just-set value (harmless — the phone already holds what it set)
- [Phase 06-04]: Sensitive-clip skip is fail-open — a 0 exclude_id (RegisterClipboardFormatW failure) or a source app that sets no ExcludeClipboardContentFromMonitorProcessing format is treated non-sensitive (RESEARCH A3 residual risk); >16 KiB skip uses String::len() UTF-8 bytes with > 16384 (exactly 16 KiB allowed). No CoInitializeEx on the clip thread (arboard needs no COM, unlike the audio thread)
- [Phase 06-04]: StubClipboard removed + stubs.rs deleted — all five server_core executor traits (MouseKeys/Media/Power/Apps/Clipboard) now have real Windows backends
- [Phase 06]: [Phase 06-05]: clipFetchReply stays a String? getter but is identity-tracked by ClipNotifier — each clip.set reply decodes to a fresh String, so an unrelated changes ping (identical reference) is never consumed as a Fetch reply; no seq/counter added
- [Phase 06]: [Phase 06-05]: HistoryStore.record does move-to-head dedupe (remove existing equal, prepend, cap 5) — the only design satisfying BOTH consecutive dedupe AND reuse-moves-to-head (D-06); clipTextTooLarge caps on UTF-8 BYTES not code units (T-06-16b); Clipboard hub tile after Apps -> Trackpad, Media, Apps, Clipboard, Power, Presenter, Browser
- [Phase 07-02]: input.blocked (proto 1.3, SRV-05/D-07) added to BOTH codecs as an additive S→C push cloning the vol.changed precedent (InputBlockedPayload{reason} + Msg::InputBlocked / InputBlockedMsg + decodeText arm); reason is a fixed vocabulary ("elevated"), never window title/exe/PII. SERVER_PROTO_VERSION deliberately NOT bumped here (still 1.2) — the version bump + authed-gated session push land in 07-05 which owns session.rs. input.blocked routed to the router S→C-only no-op group (client sending it is ignored silently). A NEW fixture family needs a matching test fn in BOTH hard-coded harnesses (Rust codec_fixtures_input_blocked + Dart input_blocked group) — neither globs dirs; the shared golden fixture proves byte-identical decode.
- [Phase ?]: [Phase 07-01]: AuthManager grown to Vec<PairedDevice{hash,name,paired_at}> with from_paired/revoke/complete_pairing_named/verify_auth_hash/paired_records + a watch::Sender<u64> change-signal; existing complete_pairing/is_paired/verify_auth signatures preserved (complete_pairing delegates to complete_pairing_named phone, verify_auth to verify_auth_hash().is_some()) so server-windows still builds; hash-only invariant unit-enforced

### Pending Todos

2 pending — see .planning/todos/pending/

- ~~Absolute pointer injection~~ — DONE in 04-01 (raw SendInput ABSOLUTE|VIRTUALDESK; moved to todos/done/)
- `noPairing` reason is overloaded: server returns authFail{noPairing} both for an unknown/revoked TOKEN (reconnect path) and for a PIN submitted with NO active pairing window (pairing path). The pairing-path case wrongly shows the revoked "no longer recognizes this phone" copy. A distinct reason code (e.g. `noPinWindow`) would let the copy say "ask your PC for a new PIN." (area: server protocol + client copy) — from the 03-07 E2E
- Server supports ONE pairing per process run: the PIN-refresh loop breaks on is_paired() and a completed pair clears the active window, so re-pairing needs a server restart. Closes when Phase 7 adds persistent token storage. (area: server) — from the 03-07 E2E

### Blockers/Concerns

- [Phase 3 — RESOLVED 2026-07-08]: Android UDP broadcast reception CONFIRMED on the owner's Xiaomi 25080RABDI (Android 16 / HyperOS) at the 03-04 early on-device checkpoint — beacons listed within seconds, continuous 2s-interval reception, no MulticastLock failure, no OEM filtering. Cleartext ws:// also proven under the new network_security_config. See 03-04-SUMMARY.md.
- [Phase 6]: apps.focus foreground-lock workarounds and EnumWindows filtering flagged as highest-fiddliness area — research recommends a phase-level spike during planning
- [Phase 2 — RESOLVED 2026-07-08]: Hard transport gate PASSED on-device (p50 = 6ms, p95 = 10ms on real WiFi, all four PAD-05 criteria). TCP_NODELAY empirical verification also resolved — sub-6ms p50 under continuous load with no traffic-pattern-dependent hitching. UDP-channel reconsideration NOT triggered. See 02-04-GATE-RESULT.md.
- [Phase 05 — KNOWN LIMITATION]: The presenter "start show" macro sends F5, which starts the slideshow in the PowerPoint desktop app (the locked SC4 target — works) but reloads the page in a web browser. Google Slides' present shortcut is Ctrl+F5, so starting a show from web Google Slides is out of scope for v1. This is a known limitation, not a bug — PowerPoint desktop is the supported presenter surface. (from quick task 260711-huz)

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260708-ejx | Fix WR-01 — pairing window re-pair loop | 2026-07-08 | 54cfcff | [260708-ejx-fix-wr-01-pairing-window-re-pair-loop](./quick/260708-ejx-fix-wr-01-pairing-window-re-pair-loop/) |
| 260711-huz | Fix browser zoom-in keymap (Plus → '=') + doc Google Slides presenter limitation | 2026-07-11 | b27f617 | [260711-huz-fix-browser-zoom-in-keymap-plus-document](./quick/260711-huz-fix-browser-zoom-in-keymap-plus-document/) |

## Deferred Items

Items acknowledged and carried forward from previous milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-07-12T12:05:00.000Z
Stopped at: Completed 07-02-PLAN.md (input.blocked proto-1.3 wire contract)
Resume file: None
