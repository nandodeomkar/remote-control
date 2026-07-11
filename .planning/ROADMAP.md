# Roadmap: Remote Control

## Overview

The journey runs strictly down the dependency graph the design spec and research locked: first the versioned wire protocol and a fully CI-tested OS-agnostic server core (the contract everything else is written against), then a deliberately early end-to-end cursor spike to retire the single make-or-break unknown — the <30ms WebSocket cursor budget on real WiFi. With transport proven, the Flutter connection layer makes discovery, PIN pairing, and silent reconnect a solved problem for every screen that follows. Then the product-defining trackpad and keyboard land with the full "feel" checklist, followed by the control-center breadth in two slices: the thin key-macro features (media, power, presenter, browser) and the fiddly push-driven pair (apps, clipboard). The final phase packages it into a daily driver: tray shell with settings/autostart/revoke, honest failure surfacing (firewall, UIPI), and the dashboard identity with dark-minimal polish.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Protocol Contract & Server Core** - Lock the wire protocol (challenge-response auth, diff-ops text, golden fixtures) and build the fully CI-tested OS-agnostic server core with mock executors (completed 2026-07-07)
- [x] **Phase 2: End-to-End Cursor Spike** - A finger on the phone moves the real Windows cursor visually instantly on real WiFi — retires the <30ms transport risk while the code is small (completed 2026-07-08 — hard gate PASS: p50 6ms / p95 10ms on real WiFi; UDP reconsideration NOT triggered)
- [x] **Phase 3: Discovery, Pairing & Connection** - Phone finds the PC automatically, pairs once via PIN, then reconnects silently and recovers from WiFi drops and IP changes (completed 2026-07-09 — on-device E2E PASS on Xiaomi + Windows 11: all five success criteria)
- [x] **Phase 4: Trackpad & Keyboard** - The product-defining screens: full trackpad feel checklist and IME-correct typing with special-key rows, sticky modifiers, and autorepeat (completed 2026-07-10 — verification passed; on-device UAT incl. WiFi-kill liveness + slow-PIN pairing re-checks)
- [x] **Phase 5: Media, Power, Presenter & Browser** - The everyday control-center extras: media/absolute volume, double-confirmed power actions, slide driving with timer, browser macros (completed 2026-07-11)
- [ ] **Phase 6: Apps & Clipboard** - Window/app management with live server push, and bidirectional clipboard with history and loop-safe auto-sync
- [ ] **Phase 7: Server Shell, Dashboard & Polish** - Tray shell with settings/autostart/revoke, firewall and UIPI status surfacing, dashboard identity and final app polish

## Phase Details

### Phase 1: Protocol Contract & Server Core

**Goal**: The wire protocol is locked as a versioned contract (challenge-response auth, diff-ops text, 9-byte binary mouse frames) and an OS-agnostic Rust server core enforces it — pairing, auth gating, routing, pause, and session cleanup all proven in CI with mock executors and zero Windows dependencies
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: CONN-07
**Success Criteria** (what must be TRUE):

  1. Shared golden fixtures in `protocol/` (auth handshake, IME-revision, emoji, rapid-backspace, binary mouse frames) decode identically in the Rust and Dart codecs — both test suites pass against the same fixture files
  2. In integration tests, a fake WebSocket client completes the full pair → challenge-response auth → input flow, and dispatch gates drop all pre-auth and paused-input traffic
  3. PIN rules are enforced (60s expiry, 5 attempts, lockout); tokens are stored only as SHA-256 hashes and the raw token never crosses the wire after pairing (HMAC-SHA256 of a server nonce)
  4. Killing the socket mid-drag releases all held keys/buttons via the session-cleanup hook (mock-executor test) — no phantom held input after disconnect
  5. `server-core` builds and passes all tests with zero Windows dependencies

**Plans**: 8 plans

Plans:

- [x] 01-01-PLAN.md — Protocol contract: SPEC.md, JSON schema, 19 golden fixtures (auth construction + diff-ops locked)
- [x] 01-02-PLAN.md — Rust workspace scaffold, full public API contracts, red test harness (walking-skeleton E2E + fixtures)
- [x] 01-03-PLAN.md — Rust codecs (binary + JSON, all families) green against fixtures
- [x] 01-04-PLAN.md — Auth: PIN lifecycle/lockout, token hashing, challenge-response (auth-proof fixture anchor)
- [x] 01-05-PLAN.md — Recording mock executors + dispatch gates, routing, held-input (CONN-07 mechanism)
- [x] 01-06-PLAN.md — Transport + full integration suite: walking skeleton green, CONN-07 headline test
- [x] 01-07-PLAN.md — Flutter/Dart SDK environment setup (human-in-loop)
- [x] 01-08-PLAN.md — Pure Dart remote_protocol package vs same fixtures + dormant CI workflow

### Phase 2: End-to-End Cursor Spike

**Goal**: A finger moving on the phone moves the real Windows cursor with visually instant response over real WiFi — the enigo MouseKeys executor (dedicated input thread, sub-pixel accumulation, DPI awareness) plus a bare Dart binary-codec sender prove the <30ms WebSocket-only budget before anything is built on top of it
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: PAD-05
**Success Criteria** (what must be TRUE):

  1. Moving a finger on the phone moves the PC cursor with no perceptible lag on real WiFi (visually instant)
  2. Measured move-frame end-to-end latency is under 30ms on the same LAN — measured on actual move frames, not just ping RTT
  3. No 40–200ms cursor hitches during slow precise movement — TCP_NODELAY verified active on both ends
  4. Slow diagonal movement tracks smoothly without drift or stair-stepping (server-side sub-pixel accumulation and DPI awareness working)

**Gate:** If the <30ms budget cannot be met on real WiFi, the transport decision is revisited (UDP mouse channel behind the existing transport abstraction) before any later phase proceeds.
**Plans**: 4 plans

Plans:

- [x] 02-01-PLAN.md — server-windows crate: enigo MouseKeys executor on a dedicated input thread, sub-pixel accumulation, DPI awareness, runnable composition root
- [x] 02-02-PLAN.md — Flutter app scaffold: TCP_NODELAY WebSocket connector (connectNoDelay) + codec-reusing MoveSender (client seams)
- [x] 02-03-PLAN.md — Wire the vertical: client handshake FSM (pair/reconnect), Listener trackpad screen, interleaved-ping latency HUD, INTERNET manifest permission (completed 2026-07-08)
- [x] 02-04-PLAN.md — Manual hard-gate: on-device p50/p95 measurement over real WiFi against all 4 criteria (human-verify) (completed 2026-07-08 — PASS: p50 6ms / p95 10ms, all 4 criteria met; pointer-accel known issue captured as todo)

### Phase 3: Discovery, Pairing & Connection

**Goal**: The phone finds the PC on the LAN, pairs once with a PIN, and from then on connects and recovers silently — the ConnectionService (reconnect FSM, beacon listener, secure token store, per-message-class send policy) makes connectivity a solved problem for every later screen
**Mode:** mvp
**Depends on**: Phase 2 (spike gate passed — transport locked)
**Requirements**: CONN-01, CONN-02, CONN-03, CONN-04, CONN-05, CONN-06
**Success Criteria** (what must be TRUE):

  1. The PC appears automatically in the app's device list within a few seconds on the same LAN, showing name and IP (machine GUID disambiguates duplicate names)
  2. First-time pairing works via the 6-digit PIN shown in a Windows notification; expiry, wrong attempts, and lockout each show a clear error with remaining wait
  3. A paired phone reconnects silently with no PIN prompt — challenge-response only, and the token never crosses the wire; a revoked/stale token returns the user to pairing with an explanation instead of a silent retry loop
  4. After a WiFi drop or a PC IP change, the app reconnects automatically (exponential backoff plus beacon re-listen, instant retry on app resume) without user action
  5. Manual IP:port entry connects when discovery fails, and the app header shows live connection status and latency

**Plans**: 7 plans

Plans:

- [x] 03-01-PLAN.md — Beacon wire contract + server-core broadcaster + PIN toast (notify.rs, RC_BEACON_PORT)
- [x] 03-02-PLAN.md — Reconnect FSM + per-message-class send policy (pure Dart, TDD — D-04/D-05/D-06 policy table)
- [x] 03-03-PLAN.md — GUID-keyed device store: secure tokens + prefs metadata (D-07/D-10)
- [x] 03-04-PLAN.md — Client discovery: beacon codec + listener + MulticastLock + scoped cleartext swap; EARLY Xiaomi on-device check
- [x] 03-05-PLAN.md — ConnectionService: FSM driver, token lifecycle, RFC1918 guard, idle-ping liveness, Riverpod providers
- [x] 03-06-PLAN.md — Device list home + PIN pairing sheet + Connect-by-IP (UI-SPEC contract)
- [x] 03-07-PLAN.md — Header status/latency chip + banner, D-01 launch wiring, trackpad slimming, phase E2E gate

**UI hint**: yes

### Phase 4: Trackpad & Keyboard

**Goal**: The phone is a genuinely usable daily mouse and keyboard — trackpad feel (raw Listener classifier, acceleration, momentum, drag lock) and typing fidelity (IME diff-ops, special rows, sticky modifiers, server-side autorepeat) match a real laptop, not a toy
**Mode:** mvp
**Depends on**: Phase 3
**Requirements**: PAD-01, PAD-02, PAD-03, PAD-04, KEY-01, KEY-02, KEY-03, KEY-04
**Success Criteria** (what must be TRUE):

  1. The trackpad handles the full gesture set: one-finger move with velocity acceleration, tap = left click, two-finger tap = right click, on-screen L/M/R buttons, two-finger scroll with momentum and instant touch-stop, long-press drag with drag lock for screen-edge drags
  2. Typing with the phone keyboard — including IME autocomplete revisions, emoji, and backspace — produces exactly the same text on the PC
  3. F1–F12, numpad, and the nav cluster (Home/End/PgUp/PgDn/Del/Esc/Tab, arrows) all work from toggleable key rows
  4. Sticky modifiers (Ctrl/Alt/Shift/Win) show visible held state, send combos like Win+D, and auto-reset after the combo; they also reset safely on disconnect
  5. Holding a key autorepeats via server-side key-down/hold and stops immediately on release

**Plans**: 10 plans (6 original + 4 gap closure)
Plans:
**Wave 1**

- [x] 04-01-PLAN.md — Server absolute pointer injection: normalize_virtual + SendInput(ABSOLUTE|VIRTUALDESK), ballistics bypass (D-01/D-02/D-03, PAD-01)
- [x] 04-03-PLAN.md — Client pure logic: gesture classifier FSM + accel curve + tuning.dart constants + volatile sendScroll (PAD-01..04 logic halves)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 04-02-PLAN.md — Server real executors: Cmd click/drag/key/text arms + keymap.rs locked key.code vocabulary (PAD-02/04, KEY-01..04 server halves)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 04-04-PLAN.md — Trackpad wiring: TrackpadDriver, L/M/R bar, drag-lock pill, momentum loop, sensitivity setting (PAD-01..04 end-to-end)

**Wave 4** *(blocked on Wave 3 completion)*

- [x] 04-05-PLAN.md — Typing slice: hidden IME field + grapheme diff-ops producer + expandable keyboard panel (KEY-01, D-07/D-08)

**Wave 5** *(blocked on Wave 4 completion)*

- [x] 04-06-PLAN.md — Key rows + sticky modifier chips + server-side autorepeat + D-12 disconnect reset (KEY-02/03/04, D-09/D-10/D-11)

**Gap closure** *(from 04-VERIFICATION.md, status: gaps_found)*

- [x] 04-07-PLAN.md — Atomic IME producer+controller sentinel reset on disconnect — closes CR-01 / T-04-03 (KEY-01, SC2)
- [x] 04-09-PLAN.md — Scroll deltas scaled by live pointer count, unhalved fling seed — closes review WR-04 (PAD-03) [gap wave 1, parallel with 04-07]
- [x] 04-08-PLAN.md — Set-based held-cap tracking + always-wired key-cap release (folds IN-04) — closes CR-02 / T-04-04 (KEY-04, SC5) [gap wave 2, after 04-07]
- [x] 04-10-PLAN.md — Session liveness deadline: half-open disconnect releases held input via existing CONN-07 cleanup — closes 04-UAT Test 5 major gap (KEY-04, SC4/SC5, T-04-04) [gap wave 3]

**UI hint**: yes

### Phase 5: Media, Power, Presenter & Browser

**Goal**: The everyday control-center extras work end-to-end from the couch — system media and accurate absolute volume, safely double-confirmed power actions, PowerPoint-standard slide driving with a timer, and browser control via key macros
**Mode:** mvp
**Depends on**: Phase 4 (keyboard key down/up model powers presenter/browser macros)
**Requirements**: MED-01, MED-02, PWR-01, PWR-02, PWR-03, PRES-01, PRES-02, BROW-01
**Success Criteria** (what must be TRUE):

  1. Play/pause, next, and previous control whatever is playing system-wide; the volume slider sets absolute volume and stays accurate when volume is changed on the PC itself (server volume-state push)
  2. Lock and sleep execute only after slide-to-confirm, and sleep actually suspends (SetSuspendState) rather than hibernating
  3. Restart and shutdown require slide-to-confirm plus the server-side confirm message — there is no single-action path to either
  4. The presenter drives slides (next/prev, start/end show, blank screen) in PowerPoint and shows an elapsed timer
  5. Browser controls (back/forward, new/close tab, refresh, zoom in/out) act on the focused browser window

**Plans**: 7 plans
**UI hint**: yes

Plans:
**Wave 1**

- [x] 05-01-PLAN.md — Protocol 1.1 amendment: vol.changed golden fixtures + Rust/Dart codecs + version bump (MED-02 wire contract, D-03)
- [x] 05-02-PLAN.md — Hub screen (D-01/D-02 reroute) + Browser tool screen end-to-end (BROW-01)

**Wave 2** *(05-03 after 05-01; 05-04 after 05-02)*

- [x] 05-03-PLAN.md — Server-core volume push seam: VolumeState watch + authed-gated session branch + after-auth snapshot + server "1.1" (MED-02)
- [x] 05-04-PLAN.md — Presenter slice: timer FSM + split-zone screen + wakelock + hub tile (PRES-01/02, D-07/D-08/D-09)

**Wave 3** *(05-05 after 05-03; 05-06 after 05-04)*

- [x] 05-05-PLAN.md — Real Windows executors: enigo media keys + IAudioEndpointVolume audio thread + WinPower (MED-01/02, PWR-01..03 server halves)
- [x] 05-06-PLAN.md — Power client slice: ConfirmTrackFsm + slide-to-confirm tracks + red countdown dialog + hub tile (PWR-01..03, D-05/D-06)

**Wave 4** *(after 05-01/03/05/06)*

- [x] 05-07-PLAN.md — Media client slice: VolChangedMsg wiring + D-04 volume store + Media screen + final 5-tile hub (MED-01/02)

### Phase 6: Apps & Clipboard

**Goal**: The phone manages PC windows and apps and moves text between devices — the two push-driven, platform-fiddly features (EnumWindows/foreground-lock workarounds, clipboard polling with echo suppression and honest Android 10+ scoping) work reliably
**Mode:** mvp
**Depends on**: Phase 3 (connection layer and server push; independent of Phases 4–5, can run in parallel with them)
**Requirements**: APPS-01, APPS-02, APPS-03, CLIP-01, CLIP-02, CLIP-03, CLIP-04
**Success Criteria** (what must be TRUE):

  1. The Apps screen lists real user windows (Alt-Tab-quality filtering, no ghost/cloaked entries); tapping focuses the window reliably and close closes it, with a clear toast if the window is gone
  2. Pinned favorites launch their apps, and the window list refreshes automatically via server push (`apps.changed`) as windows open and close
  3. The user can send the phone clipboard to the PC and fetch the PC clipboard to the phone, each with one tap
  4. With auto-sync enabled, a PC copy appears on the phone live and a phone copy syncs on app resume (Android 10+ limit surfaced honestly) — with no sync loops thanks to content-hash echo suppression
  5. The last 5 clipboard entries are visible and reusable from history

**Plans**: 7 plans
**UI hint**: yes

Plans:
**Wave 1**

- [ ] 06-01-PLAN.md — Apps wire contract (WindowInfo icon/path, protocol 1.2) + apps.changed push seam

**Wave 2** *(after 06-01)*

- [ ] 06-02-PLAN.md — Apps thread + WinApps executor: real windows, Alt-Tab filter, icons, focus/close/launch
- [ ] 06-03-PLAN.md — Apps client: screen + favorites (pin-from-window) store + hub tile

**Wave 3** *(06-04 after 06-01/02; 06-05 after 06-03)*

- [ ] 06-04-PLAN.md — Clipboard send/fetch: clip thread + WinClipboard + clip.changed seam + sensitive/echo skip
- [ ] 06-05-PLAN.md — Clipboard client: send/fetch + last-5 history + hub tile

**Wave 4** *(after 06-04/05)*

- [ ] 06-06-PLAN.md — Clipboard auto-sync + client echo suppression + Android 10+ resume-sync

**Wave 5** *(after all)*

- [ ] 06-07-PLAN.md — On-device UAT gate (SC1–SC5 + wire-size guard)

### Phase 7: Server Shell, Dashboard & Polish

**Goal**: The system is a daily-driver product — the server lives quietly in the tray with settings, autostart, and device revoke; failures surface honestly (firewall self-test, UIPI status); and the app gets its final dashboard identity with dark-minimal polish, haptics, and keep-awake
**Mode:** mvp
**Depends on**: Phase 5, Phase 6
**Requirements**: SRV-01, SRV-02, SRV-03, SRV-04, SRV-05, UI-01, UI-02
**Success Criteria** (what must be TRUE):

  1. The server lives in the tray with a status tooltip (connected device count); pause-input drops input while keeping the connection alive; quit works; the tray icon survives an Explorer restart
  2. With autostart enabled, the server starts with Windows after a reboot; the toggle turns it off cleanly
  3. The settings window manages device name, port, clipboard sync, and the paired-device list — a revoked phone is disconnected and must re-pair
  4. A firewall-blocked port produces a tray warning with a fix hint at startup, and input blocked by an elevated window (UIPI) shows a clear status on the phone instead of failing silently
  5. The dashboard home shows the 8 tool tiles with the persistent trackpad quick-bar on every screen, dark minimal theme (#0E0F12, blue accent), haptic feedback toggle, and keep-awake during trackpad/presenter use

**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 (Phase 6 may run in parallel with Phases 4–5 — it depends only on Phase 3)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Protocol Contract & Server Core | 8/8 | Complete    | 2026-07-07 |
| 2. End-to-End Cursor Spike | 4/4 | Complete — gate PASS (p50 6ms / p95 10ms) | 2026-07-08 |
| 3. Discovery, Pairing & Connection | 7/7 | Complete — on-device E2E PASS | 2026-07-09 |
| 4. Trackpad & Keyboard | 10/10 | Complete   | 2026-07-10 |
| 5. Media, Power, Presenter & Browser | 7/7 | Complete    | 2026-07-11 |
| 6. Apps & Clipboard | 0/7 | Planned — ready to execute | - |
| 7. Server Shell, Dashboard & Polish | 0/TBD | Not started | - |
