# Project Research Summary

**Project:** Remote Control (phone-as-remote-input: Flutter Android client + Rust Windows tray server)
**Domain:** LAN remote input / control-center apps (Remote Mouse / Unified Remote / KDE Connect class)
**Researched:** 2026-07-07
**Confidence:** HIGH

## Executive Summary

This is a phone-as-remote-input product: an Android app that acts as trackpad, keyboard, media/volume, app-launcher, clipboard, and power remote for a Windows PC over LAN. Every comparable system (KDE Connect, RustDesk, Remote Mouse) converges on the same five-part shape the design spec already locks: a client with a single connection service, a two-plane wire protocol (fire-and-forget binary mouse frames + reliable JSON), a server dispatcher with auth/pause gates, and OS-agnostic executor traits with platform-specific implementations. The spec-locked stack (Flutter 3.44 + Riverpod 3; Rust with tokio, tokio-tungstenite, enigo, tray-icon, arboard, eframe) validates cleanly against the 2026 ecosystem with no replacements needed.

The recommended approach: land the versioned protocol contract (schemas + shared golden fixtures) first, build server-core against mock executors (fully CI-testable, zero Windows deps), then pull a **thin end-to-end latency spike forward** (bare trackpad to enigo to real cursor) to retire the project's only make-or-break unknown: the <30ms WebSocket-only cursor budget. Everything after that (remaining executors, screens, tray shell) is known-buildable breadth. The product is judged almost entirely on trackpad *feel*: pointer acceleration, sub-pixel accumulation, tap state machine, drag lock, scroll momentum, and TCP_NODELAY are what separate "real trackpad" from "cheap toy."

Two research findings should amend the spec before any code is written. First, the current auth flow sends the raw 32-byte token over plaintext ws:// -- switch to nonce challenge-response (HMAC-SHA256) now, while the protocol is greenfield (~30 lines each side; retrofitting later is a breaking protocol bump). Second, the text message must be diff-ops ({backspaceCount, insertText} of *committed* text), not full-string snapshots -- IME autocomplete revision is KDE Connect most notorious bug class and a wire-format decision. Remaining key risks are platform realities to design around: UIPI silently eats input near elevated windows, Windows "sleep" via shutdown.exe actually hibernates, UDP broadcast discovery fails four independent ways (always ship manual IP entry), and stuck keys/buttons after mid-drag disconnect require server-side held-state release on session close.

## Key Findings

### Recommended Stack

The locked stack survives 2026 validation intact; all versions verified against crates.io/pub.dev on 2026-07-07. Details in STACK.md, including exact windows-crate feature flags and Cargo/pubspec manifests.

**Core technologies:**
- **Rust server:** tokio 1.52 + tokio-tungstenite 0.29 (WS, binary+text frames), enigo 0.6 (SendInput injection; not Sync -- dedicated input thread + mpsc), tray-icon 0.24 (must be created on a win32 event-loop thread), arboard 3.6 (clipboard, poll for changes), windows 0.62 (Core Audio volume, EnumWindows, ShellExecute, SetSuspendState), eframe/egui 0.35 for the settings window
- **Flutter app:** Flutter 3.44, flutter_riverpod 3.3 (v3 API, not v2 tutorials), web_socket_channel 3.0, dart:io RawDatagramSocket for the UDP beacon (no package), flutter_secure_storage 10.x (token only; treat null read as authFail), wakelock_plus, shared_preferences for non-secrets
- **Structure:** cargo workspace server-core (zero OS deps) + server-windows; protocol/ directory with JSON Schema + golden fixtures consumed by both codecs

Notable avoid-list: udp pub package (stale), original wakelock, Riverpod 2 StateNotifier patterns, sha2 0.10, GestureDetector for the trackpad surface.

### Expected Features

**Must have (table stakes -- free tier of every competitor):**
- Trackpad with the full *feel* checklist: velocity acceleration curve, sub-pixel delta accumulation, tap-vs-move discrimination with two-finger grace period, drag lock at screen edge, scroll momentum with instant touch-stop, TCP_NODELAY
- Keyboard: system IME text (diff-based), special-key rows (modifiers/F-keys/arrows), sticky modifiers with visible state + auto-reset, server-side autorepeat on held keys
- Media keys + volume; LAN auto-discovery; PIN pairing; silent reconnect (backoff + beacon re-listen, lifecycle-triggered instant reconnect on app resume); presenter macros; server tray with pause-input + autostart; connection status/latency; haptics

**Should have (differentiators):**
- Everything free, no ads/account (structural -- the reason the project exists)
- Absolute volume slider with server state push; app launcher/switcher (no competitor has it); clipboard manual-first + history with auto-sync opt-in OFF; credible security (challenge-response, LAN-only, confirmed power) -- Remote Mouse shipped 6 unpatched CVEs; this is a real differentiator

**Defer (v1.x / v2+):**
- Wake-on-LAN, UDP mouse channel (only if measured jitter), gyro presenter pointer, per-device profiles; iOS/Linux/macOS, file transfer, widgets, installer/store
- **Anti-features (do not build):** custom in-app keyboard, absolute cursor mapping, gyro air-mouse, BT/cloud transports, plugin remotes, default-on clipboard sync, screen mirroring

### Architecture Approach

The spec boundaries match how every comparable system is built, with two above-median strengths: the versioned protocol/ contract with shared fixtures, and executor traits in an OS-agnostic core (exactly where KDE Connect and RustDesk place portability). Enforce from day one: server-core has zero Windows deps and passes tests with mock executors; Flutter screens never touch the socket (one ConnectionService singleton owns the reconnect FSM and per-message-class send policy); traits speak protocol-level types only (no HWNDs).

**Major components:**
1. protocol/ -- spec + JSON Schemas + golden fixtures; both codecs prove equivalence against them
2. server-core -- codec, transport (WS + UDP beacon, session registry with mpsc fan-out), dispatch (parse -> auth gate -> pause gate -> route), auth/PIN/lockout, 5 executor traits
3. server-windows -- trait impls (enigo, Core Audio, Win32, arboard) + tray/settings/autostart shell; main thread owns win32 pump + tray, tokio on background threads
4. Flutter app -- ConnectionService (FSM, beacon listener, token store, send policy), protocol codecs, feature folders (controller + widgets), shell

Key patterns: two-plane protocol (9-byte binary hot path, JSON reliable path -- button/drag state on the reliable plane); per-message-class disconnect policy (drop mouse deltas, queue up to 10 text, reject power); dual-path reconnect (backoff + beacon GUID match for DHCP changes); clipboard echo suppression via last-written hash.

### Critical Pitfalls

Top 5 of 12 (full list with phase mapping in PITFALLS.md):

1. **Plaintext token over ws:// (spec flaw)** -- switch auth to nonce challenge-response HMAC before codecs are written; global (not per-IP) lockout; never log tokens/PINs/text/clipboard
2. **Nagle + tiny frames = 40-200ms cursor hitches** -- set_nodelay(true) on both ends (Dart side may need non-default WebSocket construction); assert in integration tests; measure move-frame RTT, not just ping
3. **IME text is a diff problem** -- commit-aware diff-ops on grapheme boundaries in the text schema; fixtures for autocomplete revision, emoji, rapid backspace
4. **Trackpad built on GestureDetector feels sticky** -- use raw Listener with a manual tap/two-finger/drag classifier; hot path bypasses the widget tree; scale deltas by devicePixelRatio; set DPI awareness on the server
5. **Stuck keys/buttons after mid-drag disconnect** -- server tracks held injected keys per session and releases all on session close/pause; mock-executor test: kill socket mid-drag

Also load-bearing: UIPI silently blocks input to elevated windows (detect + surface status, never run elevated); shutdown.exe /h hibernates -- use SetSuspendState(FALSE,...) for sleep; apps.focus / EnumWindows need the foreground-lock workaround stack and Alt-Tab filtering; discovery needs per-interface subnet broadcast + Android MulticastLock + manual IP fallback; Android 10+ makes background phone-to-PC clipboard sync impossible (scope UI copy honestly); tray/autostart threading model must be set in the first server scaffold.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Protocol Contract
**Rationale:** Everything depends on it; changing it later ripples through two languages. The two spec amendments (challenge-response auth, diff-ops text) are wire-format decisions that must be settled here.
**Delivers:** protocol/SPEC.md, JSON Schemas, binary frame layout, golden fixtures (including IME-revision, emoji, auth-handshake cases)
**Addresses:** protocol-first differentiator
**Avoids:** Pitfalls 9 (plaintext token) and 11-schema (text snapshots)

### Phase 2: Server Core (mock executors)
**Rationale:** Fully CI-testable with zero OS dependencies; proves auth gating, session FSM, and routing before any Windows code.
**Delivers:** Rust codecs (fixture-tested), transport with TCP_NODELAY + session registry, dispatch gates, PIN/token/lockout, 5 executor traits + mocks, session-cleanup (release-held) hook, integration test: fake WS client pair/auth/input/pause/revoke
**Uses:** tokio, tokio-tungstenite, sha2, rand
**Avoids:** Pitfalls 3 (NODELAY asserted), 12 (cleanup hook), 9 (global lockout)

### Phase 3: E2E Latency Spike (MouseKeys + throwaway trackpad)
**Rationale:** The <30ms WebSocket-only cursor budget is the only unknown that can invalidate a locked decision (transport). Retire it while the code is small.
**Delivers:** enigo MouseKeys impl (dedicated input thread, sub-pixel accumulation, DPI awareness), headless server run, Dart binary codec + bare trackpad page, measured move-frame latency on real WiFi. **Gate: visually-instant cursor.**
**Avoids:** Pitfalls 2 (delta scaling decision), 3 (real-WiFi validation), 1 (UIPI detection lands with the executor)

### Phase 4: Flutter Connection Layer + Discovery/Pairing
**Rationale:** All screens sit on ConnectionService; building screens first forces mock-churn.
**Delivers:** Reconnect FSM (backoff + beacon re-listen in parallel, lifecycle resume reset), UDP beacon listener + MulticastLock, manual IP entry, PIN pairing UI, secure token storage (null-read -> re-pair), per-class send policy
**Avoids:** Pitfalls 5 (lifecycle reconnect), 6 (discovery robustness -- per-interface broadcast lands server-side here too)

### Phase 5: Trackpad + Keyboard (the product-defining screens)
**Rationale:** The product is judged on these two screens; keyboard key down/up model unblocks presenter/browser macros for free.
**Delivers:** Real trackpad on Listener with full feel checklist; keyboard with IME diffing, special rows, sticky modifiers, server-side autorepeat
**Avoids:** Pitfalls 4 (gesture classification), 11 (IME diffing), 12 (drag + modifier state)

### Phase 6: Control-Center Executors + Screens
**Rationale:** Each is an isolated trait impl; dispatch already routes them. Media/power/presenter/browser are thin; apps is the fiddly one.
**Delivers:** Media (Core Audio absolute volume + state push), Power (SetSuspendState sleep, confirm expiry), Apps (Alt-Tab-filtered EnumWindows, focus workaround stack, apps.changed push), Clipboard (poll + echo suppression, honest Android-10 scoping), corresponding screens
**Avoids:** Pitfalls 10 (Win32 realities), 7 (clipboard loops)

### Phase 7: Server Shell + Polish
**Rationale:** Pure UX packaging; nothing depends on it -- but the tray threading model was already set in Phase 2/3 scaffolding.
**Delivers:** Tray (pause, revoke, TaskbarCreated re-add), settings window, quoted autostart Run key, single-instance guard, port/firewall self-test + hint copy, file logging with redaction, WiFi low-latency lock, haptics/keep-awake, dashboard/quick-bar
**Avoids:** Pitfall 8 (autostart/tray traps); reboot + Explorer-kill + battery smoke pass gates release

### Phase Ordering Rationale

- Protocol -> core -> spike -> connection -> screens follows the strict dependency graph; each layer is testable against the previous with no forward references.
- The E2E spike is pulled forward deliberately: it is the only risk that can invalidate a locked decision; everything else is known-buildable.
- Keyboard before presenter/browser makes those near-free (they are key macros). Push-capable protocol (Phase 1/2) lands before the three push consumers (volume state, apps, clipboard).
- Tray threading model is fixed in the first server scaffold even though tray UI ships last -- retrofitting it is painful.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3 (latency spike):** empirical, not documentary -- Dart-side TCP_NODELAY plumbing needs verification against the chosen WebSocket construction path; enigo Windows behavior flagged MEDIUM confidence
- **Phase 6 (apps executor):** apps.focus foreground-lock workarounds and EnumWindows/DWM-cloaking filtering are the highest-fiddliness area -- PITFALLS.md explicitly flags a phase-level spike here

Phases with standard patterns (skip research-phase):
- **Phases 1, 2, 4:** protocol/fixture design, tokio-tungstenite server shape, and Flutter reconnect FSM are well-documented with authoritative references already collected
- **Phases 5, 7:** behavior checklists in FEATURES.md/PITFALLS.md are already implementation-grade

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All versions verified against crates.io/pub.dev registries 2026-07-07; only Android UDP broadcast behavior is LOW (device-dependent) |
| Features | MEDIUM-HIGH | Competitor sets verified against official sites/CVE records; input-feel details grounded in libinput docs; paywall boundaries shift over time |
| Architecture | HIGH | Structure converges across multiple OSS systems; MEDIUM for latency specifics pending the Phase 3 spike |
| Pitfalls | HIGH | Win32/Android behaviors from official docs; enigo/tray-icon specifics MEDIUM-HIGH from maintainer issues |

**Overall confidence:** HIGH

### Gaps to Address

- **<30ms cursor budget over WebSocket/TCP on real WiFi:** unprovable from documents -- Phase 3 spike is the resolution; transport trait keeps a UDP fallback cheap
- **Dart TCP_NODELAY:** dart:io likely sets it by default via HttpClient, but must be verified empirically for the chosen web_socket_channel path
- **Android UDP broadcast reception variance:** test on the owner's device early in Phase 4; MulticastLock + manual IP entry are the mitigations either way
- **enigo 0.7 risk:** crate release lags active repo; pin =0.6.1 if a breaking release lands mid-project
- **tray-icon TaskbarCreated re-add:** MEDIUM confidence the crate handles it -- test by killing Explorer in Phase 7

## Sources

### Primary (HIGH confidence)
- crates.io / pub.dev registry APIs (2026-07-07) -- all pinned versions
- Microsoft Learn -- UIPI/UIAccess, relative mouse acceleration, DPI scaling, firewall profiles, FGS types
- Flutter docs -- gesture system, pointer resampling, logical pixels; Riverpod v3 migration docs
- libinput docs -- tap state machine, drag lock, pointer acceleration (reference implementation for feel)
- tray-icon / enigo / flutter_secure_storage official docs + changelogs
- KDE Connect / RustDesk source (invent.kde.org, GitHub) -- architecture precedent
- Mouse Trap CVE disclosure (CVE-2021-27569..27574) -- Remote Mouse security failures

### Secondary (MEDIUM confidence)
- GitHub issue trackers (enigo #98/#140, GSConnect #1831, KDE bugs 391083/466644, Mirror #2878) -- injection gaps, IME bugs, Android broadcast filtering
- tokio-tungstenite server example + websocket.org reconnection guidance; TCP_NODELAY/Nagle analyses (Brooker, RDP fixes)
- Competitor store listings and review roundups -- paywall boundaries, complaint patterns

### Tertiary (LOW confidence)
- Android UDP broadcast / MulticastLock device behavior -- training-data + community reports; validate on target device early

---
*Research completed: 2026-07-07*
*Ready for roadmap: yes*
