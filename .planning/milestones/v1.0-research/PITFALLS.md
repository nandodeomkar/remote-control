# Pitfalls Research

**Domain:** Phone-as-remote-input (Flutter Android client + Rust Windows input-injection server over LAN)
**Researched:** 2026-07-07
**Confidence:** HIGH overall (Win32/Android platform behaviors verified against official docs; enigo/tray-icon specifics MEDIUM from GitHub issues; verify at implementation)

Note on process: `gsd-tools` seams (research-plan / classify-confidence / research-store) were not available in this environment; research used built-in WebSearch/WebFetch with manual confidence tiers (official platform docs = HIGH, maintainer GitHub issues = MEDIUM-HIGH, community reports = MEDIUM).

## Critical Pitfalls

### Pitfall 1: SendInput silently fails against elevated windows (UIPI)

**What goes wrong:**
The cursor and keyboard "randomly stop working." When the foreground window belongs to an elevated process (Task Manager run as admin, an installer, regedit, an admin terminal), Windows UIPI blocks injected input from the non-elevated server process. `SendInput` returns success-ish behavior but the input is eaten. The UAC consent prompt itself runs on the *secure desktop*, where no injection from the user desktop works at all — the user taps the phone, nothing happens, and they conclude the app is broken.

**Why it happens:**
UIPI (integrity levels) blocks lower-IL processes from sending input to higher-IL windows; the secure desktop is a separate desktop entirely. This is by design and there is no clean bypass short of a UIAccess-signed binary in a secure location (requires a trusted code-signing cert — not realistic for v1) or running the server elevated (which breaks autostart, see Pitfall 8).

**How to avoid:**
- Accept the limitation for v1; do NOT run the server elevated by default.
- Detect it: on the server, periodically (or on `err`-worthy conditions) check whether the foreground window's process is higher-integrity than the server (`GetForegroundWindow` → `OpenProcess` → token integrity level). If so, push an `err`/status message so the phone shows "PC is showing an admin window — input paused by Windows" instead of dead silence.
- Document in settings/help: "input doesn't work over admin apps or UAC prompts."

**Warning signs:**
Manual smoke testing only ever done against normal apps; bug reports like "trackpad freezes randomly, reconnecting fixes it" (it doesn't — the user just switched windows).

**Phase to address:**
Core input phase (trackpad/keyboard executor) — add the foreground-elevation detection there; document limitation in the server settings/help phase.

Confidence: HIGH (Microsoft UIPI/UIAccess docs, longstanding Win32 behavior).

---

### Pitfall 2: Relative mouse deltas are mangled by Windows pointer acceleration and phone DPI variance

**What goes wrong:**
Cursor sensitivity feels wildly different across phones, and non-linear on the PC: slow swipes barely move, fast swipes teleport. Two causes stack: (1) Windows applies "Enhance pointer precision" (acceleration) and the mouse-speed slider to *injected relative* `MOUSEEVENTF_MOVE` events, so the same dx lands differently depending on user's mouse settings and swipe speed; (2) Flutter reports deltas in *logical* pixels, so a 1x-density phone and a 3x-density phone send very different deltas for the same physical finger travel.

**Why it happens:**
Microsoft documents that relative mouse motion is subject to mouse speed and the two acceleration thresholds. Developers test on one phone + one PC and hard-code a sensitivity constant.

**How to avoid:**
- Phone side: multiply gesture deltas by `devicePixelRatio` (send physical pixels) before applying the user sensitivity setting, so all phones feel the same.
- Server side: pick a strategy deliberately. Option A (simple, v1-recommended): inject relative moves and accept that Windows acceleration applies — it feels "native" and matches Remote Mouse. Option B (deterministic): maintain position via `GetCursorPos` + absolute `SendInput` with `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK` to bypass acceleration — but this drags in multi-monitor/virtual-desktop coordinate math (0–65535 normalization) and mixed-DPI monitor traps. Do not half-do both.
- Set the process DPI awareness context at server startup (enigo docs explicitly recommend this); without it, coordinate APIs are DPI-virtualized on scaled displays.
- Expose sensitivity as a client setting (already in spec) and test on a 100% and a 150% scaled display, and on two phones with different densities.

**Warning signs:**
Sensitivity constant tuned once on the dev phone; no `devicePixelRatio` anywhere in the gesture code; no `SetProcessDpiAwarenessContext` call in server startup.

**Phase to address:**
Core input phase (trackpad). The relative-vs-absolute decision should be made when writing the `MouseKeys` executor, not discovered later.

Confidence: HIGH for Windows acceleration behavior (Microsoft docs); HIGH for Flutter logical pixels (Flutter docs).

---

### Pitfall 3: Nagle's algorithm + per-event frames adds 40–200ms cursor latency spikes

**What goes wrong:**
Cursor motion is smooth in bursts but hitches or "rubber-bands," especially in one direction of traffic. Small 9-byte WebSocket frames sent at 60–120Hz over TCP interact with Nagle's algorithm and delayed ACKs, causing the OS to buffer tiny packets. The <30ms end-to-end budget dies here, not in the network.

**Why it happens:**
Both tokio's `TcpStream` and Dart sockets have Nagle enabled by default. Nobody notices in loopback testing; it shows up on real WiFi.

**How to avoid:**
- Set `TCP_NODELAY` on both ends: `stream.set_nodelay(true)` on the accepted socket before handing it to tungstenite; on Dart, `socket.setOption(SocketOption.tcpNoDelay, true)` (requires creating the WebSocket from a socket you control, e.g. `WebSocket.fromUpgradedSocket`, rather than the default `WebSocket.connect` path — verify the chosen package exposes this).
- Do not add app-level batching/queues on the mouse path; send-and-forget per input event, drop when the socket's not writable.
- Make the latency debug overlay (already in spec) measure move-frame round trips, not just ping, so this is visible early.

**Warning signs:**
Latency overlay shows RTT ~1–3ms but cursor feels laggy; smooth on emulator/localhost, janky on phone.

**Phase to address:**
Transport/protocol foundation phase — bake `TCP_NODELAY` into both transport implementations and assert it in integration tests.

Confidence: HIGH (classic TCP behavior; tokio/Dart defaults verified).

---

### Pitfall 4: GestureDetector touch-slop and gesture-arena delays make the cursor feel "sticky"

**What goes wrong:**
The first ~8–18 logical pixels of every swipe are swallowed before `onPanUpdate` fires (touch slop for drag disambiguation), and tap-vs-drag arbitration adds delay. The cursor ignores small precise movements — exactly the movements that matter for a trackpad. Separately, rebuilding widgets on every pointer event (setState/provider updates per move for e.g. a live coordinate display) creates jank at 120Hz input.

**Why it happens:**
`GestureDetector` is designed for UI gestures, not raw input streaming. The gesture arena must decide tap vs. pan vs. two-finger, and that costs dead-zone and time.

**How to avoid:**
- Use `Listener` (raw `PointerDown/Move/Up` events) for the trackpad surface and implement tap/two-finger/long-press classification manually with your own thresholds and timers. This is more work but is the difference between "feels like a trackpad" and "feels like a phone app."
- Keep the hot path out of the widget tree: pointer handler → controller → binary encoder → sink, with zero `setState`/provider notifications per move event. Status/latency UI updates go through throttled providers (e.g. 4Hz), and use Riverpod `select` to scope rebuilds.
- Two-finger scroll: accumulate fractional wheel units server-side or client-side — enigo's scroll takes integer wheel clicks; naive pixel→click conversion either fires nothing or machine-guns scroll events.

**Warning signs:**
Trackpad implemented with `GestureDetector.onPanUpdate`; cursor doesn't respond to tiny nudges; DevTools shows frame rebuilds during trackpad use.

**Phase to address:**
Core input phase (trackpad screen). Choose `Listener` from the start — retrofitting gesture classification is a rewrite of the screen.

Confidence: HIGH (Flutter gesture system docs; flutter/flutter #54359 and trackpad-gesture breaking-change docs).

---

### Pitfall 5: Android kills or throttles the connection the moment the screen dims or app backgrounds

**What goes wrong:**
User switches to another app or the screen times out during a presentation; the socket dies (Doze, app standby, WiFi power-save), and on return the user stares at "reconnecting" for up to the 10s backoff cap. Worse: WiFi power-save adds 100–300ms latency spikes *even while the app is foregrounded* on some devices once the radio idles.

**Why it happens:**
Doze/standby suspend network for backgrounded apps; developers test with the app pinned open and USB-attached (charging disables Doze).

**How to avoid:**
- Accept that background persistence is not needed for v1's UX (all features are used with app open) — but design `ConnectionService` around process-lifecycle reality: listen to `AppLifecycleState`, and on `resumed`, immediately reset backoff and attempt reconnect + beacon listen (don't wait out the current backoff timer). This one line is the difference between 0.5s and 10s perceived reconnect.
- Acquire a WiFi low-latency lock (`WifiManager.WIFI_MODE_FULL_LOW_LATENCY`, effective when app is foreground + screen on) during trackpad/presenter use to suppress WiFi power-save latency spikes; release it when leaving those screens. Pairs with the keep-awake already in spec.
- If a foreground service is ever added for background clipboard sync (see Pitfall 7), Android 14+ requires a declared service type (`connectedDevice` fits: needs `FOREGROUND_SERVICE_CONNECTED_DEVICE` + e.g. `CHANGE_WIFI_MULTICAST_STATE`) — and Android 15 hard-kills `dataSync`-typed services at 6h. Don't pick `dataSync`.
- Presenter mode is the high-risk scenario (long idle periods between slide taps): keep-awake + foreground use covers it, but test 10 minutes idle → tap next.

**Warning signs:**
All testing done while USB-debugging (charging = no Doze); reconnect logic has no lifecycle hook; latency spikes appear only on battery.

**Phase to address:**
Connection/reconnect phase for lifecycle-aware backoff reset; trackpad/presenter polish phase for the WiFi lock.

Confidence: HIGH (Android Doze/FGS official docs); WiFi lock behavior MEDIUM-HIGH (documented API, device-dependent effect).

---

### Pitfall 6: UDP broadcast discovery fails on real networks for four unrelated reasons

**What goes wrong:**
Discovery works on the dev network and fails at a friend's house / on hotspot / after a Windows update. Independent causes: (a) Windows sends `255.255.255.255` broadcasts out **one** interface chosen by the routing table — a VPN, WSL, Hyper-V, or VirtualBox virtual adapter silently absorbs the beacon; (b) the phone's AP has client/AP isolation enabled (guest networks, many hotspots) and unicast/broadcast between clients is dropped; (c) Windows Firewall blocks the *WebSocket* inbound connection when the network is on the Public profile or the user dismissed the first-run prompt — beacons arrive (outbound is allowed) so the PC is listed, but connecting hangs; (d) some Android devices filter broadcast packets aggressively, especially screen-off, unless a `MulticastLock` is held.

**Why it happens:**
Broadcast is fine on a one-router home LAN and quietly assumes: single interface, no isolation, firewall configured, unfiltered chipset.

**How to avoid:**
- Server: enumerate all up, non-loopback IPv4 interfaces and send a subnet-directed broadcast (e.g. `192.168.1.255`) on each, not one global broadcast. Re-enumerate periodically (interfaces change).
- Phone: acquire `WifiManager.MulticastLock` while the discovery screen is open (needs `CHANGE_WIFI_MULTICAST_STATE`); release after.
- Always provide manual "connect by IP:port" entry as a fallback — this single feature converts every discovery failure from a dead end into a workaround. Beacon list is a convenience, not the only path.
- The spec's startup port self-test is good but tests the wrong direction if it only binds locally: have the settings window show the firewall rule state or instruct `netsh advfirewall` command; the beacon-listed-but-connect-hangs case (c) is the most confusing for users, so the phone's connect timeout error should say "PC found but connection blocked — check Windows Firewall."
- Beacon includes port (per spec) — make sure discovery and manual-IP paths share one connect routine so fixes apply to both.

**Warning signs:**
Discovery tested only on one home network; server broadcasts once to `255.255.255.255`; no manual IP entry in the connect screen; PC has Docker/WSL/VPN installed and discovery "sometimes" fails.

**Phase to address:**
Discovery & pairing phase — per-interface broadcast, multicast lock, and manual IP entry are all scoped there. Firewall-specific error copy belongs to the same phase.

Confidence: HIGH for firewall-profile and per-interface broadcast behavior (Microsoft docs, classic Winsock behavior); MEDIUM-HIGH for Android broadcast filtering (device-dependent, widely reported).

---

### Pitfall 7: Clipboard auto-sync — infinite echo loops, and Android 10+ makes phone→PC background sync impossible

**What goes wrong:**
Two failure modes. (1) Echo loop: phone sends clipboard → server sets Windows clipboard → server's change-poller sees "change" → pushes `clip.changed` → phone sets its clipboard → phone's watcher fires → sends `clip.set` → loop; contents ping-pong forever, or with two phones connected, three-way ping-pong. (2) Platform wall: since Android 10, apps can only read the clipboard while they are the focused app (or the active IME). "Auto-sync" of phone→PC when the user copies in another app **cannot work** — the app can't see the clipboard from the background. Users will file this as a bug.

**Why it happens:**
Change detection can't distinguish "user copied something" from "I just wrote that." And the Android restriction is invisible until you test copy-in-Chrome → paste-on-PC.

**How to avoid:**
- Echo suppression: after the server writes the clipboard, snapshot `GetClipboardSequenceNumber()` (or a content hash) and ignore poller hits matching its own write; same pattern on the phone (remember last-received content, skip resend if identical). Content-hash comparison also handles the two-phone case.
- Scope auto-sync honestly: PC→phone auto-push works only while the app is foregrounded (it must be, to set the phone clipboard reliably too); phone→PC "auto" only fires on app resume (check clipboard when app regains focus — allowed) plus the manual send button. Design the UI copy around this ("syncs when you open the app") instead of promising background magic.
- Windows clipboard opens fail transiently when another process holds it — arboard retries some of this, but wrap clipboard ops in retry + `err` response, never panic/unwrap on clipboard failures (a crashed server from a clipboard race is a real remote-desktop-tool failure mode; rdpclip.exe's fragility is the cautionary tale).
- Never log clipboard contents (file logging is in spec — easy leak).

**Warning signs:**
Auto-sync demo works when both apps are foreground and you only copy once; CPU/network chatter when idle with auto-sync on (loop!); spec/UI text promising "copy anywhere on your phone."

**Phase to address:**
Clipboard feature phase — echo suppression is core logic there; the Android 10 limitation must be reflected in the roadmap's feature definition *before* UI copy is written.

Confidence: HIGH (Android 10 clipboard restriction is documented platform behavior; GetClipboardSequenceNumber is the standard Win32 pattern).

---

### Pitfall 8: Autostart + tray integration has five independent traps

**What goes wrong:**
(a) If the exe manifest ever requests `requireAdministrator`, the HKCU `Run` key silently refuses to launch it at login — autostart just doesn't happen. (b) Unquoted `Run` value with a space in the path (`C:\Program Files\Remote Control\server.exe`) breaks launch. (c) Autostarted processes get `C:\Windows\System32` as working directory — any relative path (icon file, config, log) fails only at boot, never in dev. (d) If Explorer restarts (crash, driver update), tray icons vanish unless the app re-adds them on the `TaskbarCreated` window message — user thinks the server died. (e) `tray-icon` needs a win32 message pump running on its thread; tokio must live on other threads, with tray menu events crossing via channels — retrofitting this threading model after building the server "async-first, tray later" is painful.

**Why it happens:**
Each is invisible in `cargo run` from a terminal. They only appear at real login on a real machine.

**How to avoid:**
- Keep the server non-elevated forever (also required by Pitfall 1 stance). Quote the Run value. Resolve all paths absolutely from `%APPDATA%` (spec already does for config — apply to logs and any assets too, and embed the tray icon in the binary).
- Structure `server-windows`'s `main` from day one as: thread 1 = win32 message pump + tray + settings window; thread 2+ = tokio runtime; communicate via channels. Verify whether the `tray-icon` crate handles `TaskbarCreated` re-add automatically (MEDIUM confidence it does in current versions) — test by killing Explorer.
- Single-instance guard (named mutex) — otherwise second launch fails on port bind with a confusing error, or worse, two beacon broadcasters.
- Expect SmartScreen/Defender friction on an unsigned bare exe (spec ships bare exe): first run shows "Windows protected your PC." Fine for personal use; note it for the future public-release gate.

**Warning signs:**
Everything tested via `cargo run`; tray icon loaded from a file path; autostart never tested through an actual reboot.

**Phase to address:**
Server platform phase (tray/autostart/settings) — the threading model belongs in the *first* server scaffolding phase even though tray UI comes later, because it dictates `main()` structure.

Confidence: HIGH for a–c (documented Windows behavior), MEDIUM-HIGH for d–e (tray-icon crate docs + community reports).

---

### Pitfall 9: Pairing security theater — plaintext token over ws:// and spoofable beacons undermine the PIN ceremony

**What goes wrong:**
The spec's flow sends the 32-byte token in the `auth` message over unencrypted WebSocket. Anyone sniffing the LAN (or running a rogue server) captures a permanent credential: a rogue device can broadcast a beacon with the paired machine's GUID, the phone silently reconnects to it, and hands over the token in plaintext — which the attacker then replays to the real server. The 6-digit PIN, lockout, and SHA-256 hashing at rest are all bypassed. Also: per-source-IP lockout is weak on a LAN where the attacker controls their own IP.

**Why it happens:**
"It's just my home LAN" — true for v1, but the design is explicitly the long-term protocol, and retrofitting auth into a wire protocol is a breaking change (protocol major-version bump, both sides).

**How to avoid:**
- Change `auth` to challenge-response *now*, while the protocol is greenfield: server includes a random nonce in its post-connect greeting; phone replies with `HMAC-SHA256(token, nonce ‖ serverGuid)`. The token never crosses the wire after pairing, replay is dead, and rogue-server beacon spoofing yields nothing usable. Cost: ~30 lines each side; cost of retrofitting later: protocol v2.
- During pairing itself, the PIN can bootstrap trust: derive/encrypt the issued token with a key derived from the PIN (even simple XOR-with-HKDF(PIN) raises the bar), or accept plaintext-once-during-pairing as a documented tradeoff for v1.
- Make lockout global (all IPs) after N total failures, not per-IP.
- Constant-time comparison for token-hash checks; never log tokens or PINs (file logging is in spec).
- Keep the "LAN-only binding" honest: binding 0.0.0.0 on a laptop that joins café WiFi is internet-adjacent; the firewall Public-profile default actually *helps* here — don't instruct users to allow the rule on Public networks.

**Warning signs:**
`auth` message schema contains the raw token; `println!/log` lines during handshake debugging; pairing tests only cover the happy path.

**Phase to address:**
Protocol design phase (schema decides challenge-response vs. raw token — must be settled before both codecs are written) and pairing phase (lockout policy).

Confidence: HIGH (protocol analysis of the approved spec; standard threat model for LAN pairing).

---

### Pitfall 10: The spec's power/apps executors rely on Win32 calls that don't do what they appear to

**What goes wrong:**
Three concrete design-spec blind spots. (a) **Sleep doesn't exist in `shutdown.exe`**: `/h` is *hibernate*, and the popular `rundll32 powrprof.dll,SetSuspendState 0,1,0` incantation also hibernates when hibernation is enabled. "Sleep" silently hibernates → laptop takes 30s to wake → user thinks remote broke the PC. (b) **`apps.focus` will fail**: Windows foreground-lock prevents a background process from stealing focus; plain `SetForegroundWindow` from the server just flashes the taskbar button. (c) **`EnumWindows` returns garbage**: dozens of invisible, cloaked (UWP ghosts), owned, and tool windows — a naive list is unusable, and `WM_CLOSE` to the wrong handle closes hidden system windows.

**Why it happens:**
Each API's happy path works in a hello-world test (focus works when *your* window called it recently; EnumWindows "returns windows").

**How to avoid:**
- Sleep: call `SetSuspendState(FALSE, FALSE, FALSE)` from `powrprof.dll` directly via the `windows` crate (bHibernate=FALSE actually sleeps); do not shell out for sleep. Keep `shutdown.exe /s /t`, `/r` for shutdown/restart and `LockWorkStation` for lock — those are fine.
- Focus: implement the standard workaround stack — try `SetForegroundWindow`; if it fails, `ShowWindow(SW_RESTORE)` for minimized windows plus the `AttachThreadInput` or synthesized-ALT-keypress trick. Test while a *different* app has focus (the realistic case), not while the server's own settings window is focused.
- Window list: apply the Alt-Tab filter: visible, no owner, not `WS_EX_TOOLWINDOW`, and not DWM-cloaked (`DwmGetWindowAttribute(DWMWA_CLOAKED)`), non-empty title. Snapshot-test on a machine with UWP apps installed.
- Also in this family: `IAudioEndpointVolume` requires per-thread COM init (`CoInitializeEx`) and the endpoint handle goes stale when the default audio device changes (headphones plugged in) — re-acquire on error rather than caching forever.

**Warning signs:**
Power executor is a `match` over `shutdown.exe` args including sleep; apps list shows "Windows Input Experience" / "Program Manager"; focus works in dev (where you just clicked the server window) but not from the couch.

**Phase to address:**
Control-center features phase (power, apps, media executors). Flag `apps.focus` and window enumeration as needing a phase-level research/spike task — this is the highest-fiddliness executor.

Confidence: HIGH for sleep/hibernate and foreground-lock behavior (documented Win32); HIGH for Alt-Tab filtering (well-known pattern).

---

### Pitfall 11: "Send-as-you-type" text with a modern IME is a diff problem, not a stream

**What goes wrong:**
Gboard autocomplete/swipe commits words, *revises* previously sent text, and maintains a composing region. A naive "send each onChanged delta" implementation double-types, drops backspaces, or types composing garbage on the PC ("thw" then "the " arrives as "thwthe"). Emoji/grapheme clusters split across messages produce mojibake. Separately, enigo's Unicode text injection (`KEYEVENTF_UNICODE`) is ignored by some apps and games, and enigo has open issues where keyboard input intermittently no-ops (enigo-rs/enigo #140).

**Why it happens:**
`TextField.onChanged` gives you the whole new string, not keystrokes; IMEs rewrite history. Everyone underestimates this.

**How to avoid:**
- Client-side, compute a proper diff between previous and current field text (common-prefix/suffix) and emit `{backspaceCount, insertText}` operations; the spec's `text` message should carry that shape (chars-or-words as committed), not raw snapshots. Handle the composing region by only sending *committed* text (compare against `TextEditingValue.composing`).
- Diff on grapheme-cluster boundaries (Dart `characters` package), never UTF-16 code units, or emoji will corrupt.
- Server-side, map backspace counts to Backspace key taps and text to enigo `text()`; document that some elevated apps/games won't accept Unicode injection (overlaps Pitfall 1).
- Add protocol fixtures for: autocomplete revision, emoji, rapid backspace — this is exactly what the shared-fixture contract tests are for.

**Warning signs:**
`text` payload is "the current full field content"; no `composing` handling; typing "the" via autocomplete on a real keyboard produces duplicates on the PC.

**Phase to address:**
Keyboard feature phase; the `text` message *schema* must be settled in the protocol phase (diff-ops vs. snapshots is a wire-format decision).

Confidence: HIGH for IME behavior (Flutter/Android IME docs); MEDIUM for enigo-specific injection gaps (GitHub issues).

---

### Pitfall 12: Stuck buttons and modifiers on the server after mid-gesture disconnect

**What goes wrong:**
User is mid-drag (mouse button held via long-press drag) or has sticky Ctrl active when WiFi blips. The spec resets sticky modifiers *client-side* on disconnect — but the *server* already injected Ctrl-down/left-button-down. The PC is left with a phantom held key: everything the user clicks is Ctrl-clicked, or the cursor drags everything. This is the single most confusing failure state for a user, and it persists until they touch the physical keyboard.

**Why it happens:**
Key/button state lives on the PC; client-side cleanup can't reach it once the socket is gone.

**How to avoid:**
- Server tracks all currently-held injected keys/buttons per session; on session close (any reason: disconnect, auth revoke, pause), inject release events for everything held. This is a small state map in the dispatcher/executor boundary.
- Same on "pause input" from tray: pausing while a drag is active must release first, or pause itself creates the phantom.
- Integration-test it: connect → drag-start → kill socket → assert release calls on the mock executor. The spec's mock-executor test harness makes this cheap.

**Warning signs:**
`MouseKeys` executor is stateless; no `on_session_end` hook in the dispatcher; manual testing never kills WiFi mid-drag.

**Phase to address:**
Core input phase (drag + sticky modifiers land there) — the session-cleanup hook should exist in the dispatcher from the transport phase.

Confidence: HIGH (logical consequence of the design; standard remote-input hygiene).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Raw token in `auth` message (per current spec) | Simplest handshake | Breaking protocol change to fix; LAN credential theft | Never — challenge-response costs ~30 lines now (Pitfall 9) |
| `GestureDetector` for trackpad | Free tap/pan classification | Sticky cursor; full screen rewrite to fix | Never for the trackpad surface; fine for all other screens |
| Single global `255.255.255.255` beacon | One-liner | Discovery fails on multi-adapter PCs (VPN/WSL/Hyper-V) | Only until Discovery phase; must ship per-interface |
| Testing only via `cargo run` / USB-attached phone | Fast iteration | Autostart, Doze, and firewall bugs ship invisibly | Acceptable per-feature; a reboot + battery + fresh-network smoke pass must gate each milestone |
| Skipping `TCP_NODELAY` plumbing on Dart side (needs non-default WebSocket construction) | Use simplest WS API | Latency spikes that no amount of app-level tuning fixes | Never — it's the hot path's foundation |
| Full-string snapshots in `text` messages | Trivial client code | IME duplication bugs; wire-format break to fix | Never — schema decision, fix costs nothing now |
| Stateless input executors (no held-key tracking) | Less code | Phantom stuck keys after disconnect | Never (Pitfall 12) |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| enigo (Windows) | Assuming injection always works; no DPI awareness | Set DPI awareness context at startup (enigo docs); treat injection as best-effort near elevated windows; pin enigo version — API churned significantly across 0.x |
| enigo scroll | Passing raw touch-pixel deltas as wheel clicks | Accumulate pixels, emit integer wheel units, carry fractional remainder |
| tray-icon | Creating tray from tokio context / no message pump | Dedicated win32 message-pump thread owns tray + settings window; channels to tokio (Pitfall 8) |
| `IAudioEndpointVolume` | Init COM once, cache endpoint forever | `CoInitializeEx` per thread; re-acquire endpoint on device-change errors |
| `shutdown.exe` | Using it for sleep (`/h` = hibernate) | `SetSuspendState(FALSE,…)` via windows crate (Pitfall 10) |
| `SetForegroundWindow` | Calling it cold from a background process | Restore-if-minimized + AttachThreadInput/ALT workaround stack (Pitfall 10) |
| `EnumWindows` | Listing everything visible-ish | Alt-Tab filter incl. DWM cloaking check (Pitfall 10) |
| arboard / Win clipboard | Unwrap on clipboard errors; trusting every change event | Retry-with-backoff; sequence-number/hash echo suppression (Pitfall 7) |
| flutter_secure_storage | Assuming reads never fail | Handle post-restore/keystore-invalidation read failures by falling back to pairing flow, not crashing |
| Registry `Run` autostart | Unquoted path; assuming elevated exe launches | Quote path; keep manifest `asInvoker` (Pitfall 8) |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Nagle + tiny frames | Cursor rubber-banding despite low ping | `TCP_NODELAY` both sides (Pitfall 3) | Immediately on real WiFi |
| Widget rebuilds per pointer event | Jank during trackpad use; DevTools shows rebuild storms | Hot path bypasses widget tree; throttled status providers with `select` | At 120Hz input on mid-range phones |
| WiFi power-save | 100–300ms spikes after a few idle seconds, battery only | `WIFI_MODE_FULL_LOW_LATENCY` lock on trackpad/presenter screens | Any phone off charger |
| Backoff cap on resume | 10s "reconnecting" when reopening app | Reset backoff on `AppLifecycleState.resumed` (Pitfall 5) | Every app switch |
| Per-message JSON on hot path | CPU + GC pressure | Already avoided by binary frames — keep clicks/keys JSON, never "optimize" moves back into JSON | N/A (design is right; don't regress) |
| Clipboard poll interval too tight | Idle CPU on server | 500ms–1s poll of `GetClipboardSequenceNumber` (cheap) rather than reading contents each tick | Always-on tray app noticed in Task Manager |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Plaintext token over ws:// | Permanent credential sniffable/replayable on LAN | Challenge-response HMAC auth (Pitfall 9) |
| Trusting beacons for reconnect identity | Rogue server harvests auth attempt | Challenge-response makes harvested data useless; never auto-send secrets on beacon match alone |
| Per-IP lockout only | LAN attacker rotates IPs freely | Global lockout counter with cooldown |
| Logging handshake/clipboard payloads | Tokens, PINs, passwords (typed text!) land in `%APPDATA%` log files | Redaction discipline: never log `text`, `clip.*`, `pin`, `auth` payloads — enforce in the one logging chokepoint |
| Non-constant-time token compare | Timing oracle (low practical risk on LAN, free to fix) | `subtle`-style constant-time compare of hashes |
| Allowing firewall rule on Public profile in docs | Server reachable on café WiFi | Instruct Private-profile-only rule; keep default-deny on Public |
| No frame-size limits pre-auth | Memory DoS from LAN | Keep tungstenite max-frame/message limits; drop non-handshake pre-auth traffic (spec already gates — verify limits too) |
| Power actions on single message | Prank/accident shuts down PC mid-work | Spec's `confirm` second message is right — ensure `confirm` is session-bound and expires (e.g. 10s), or a stale confirm executes later |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent input death near admin windows | "App randomly breaks" | Detect elevated foreground window, show status on phone (Pitfall 1) |
| Discovery-only connect flow | Any network quirk = dead end | Manual IP:port entry always available (Pitfall 6) |
| "Auto-sync clipboard" implying background sync | Broken promise on Android 10+ | Copy that says "syncs when app opens"; sync-on-resume (Pitfall 7) |
| Full backoff wait on app resume | 10s stare at spinner | Lifecycle-triggered instant reconnect (Pitfall 5) |
| Sleep that hibernates | 30s wake, user panic | Real `SetSuspendState` sleep (Pitfall 10) |
| Tap-to-click firing on two-finger-tap start | Ghost left-clicks during right-click attempts | Manual gesture classifier with two-finger grace window (Pitfall 4) |
| Cursor deltas queued during blips | Cursor teleports on reconnect | Spec already drops them — keep it; extend the same rule to scroll frames |
| PIN notification via Windows toast only | Toast missed (focus assist/do-not-disturb suppresses it) | Also surface PIN in tray tooltip/settings window; note Focus Assist suppression in pairing UI |

## "Looks Done But Isn't" Checklist

- [ ] **Trackpad:** works on dev phone — verify on a second phone with different `devicePixelRatio`, and on a 150% DPI-scaled Windows display
- [ ] **Latency:** ping RTT low — verify *move-frame* latency on battery, screen auto-dim approaching, 3m from router
- [ ] **Reconnect:** works after server restart — verify after phone WiFi toggle, PC sleep/wake (new DHCP lease), and app backgrounded 10+ min
- [ ] **Drag/modifiers:** work — verify kill-WiFi-mid-drag leaves no stuck button on PC (Pitfall 12)
- [ ] **Keyboard:** typing works — verify Gboard autocomplete revision, swipe typing, emoji, hold-backspace
- [ ] **Discovery:** finds PC at home — verify with VPN client connected on PC, on phone hotspot, and on Public-profile network; verify manual IP fallback
- [ ] **Autostart:** Run key written — verify through an actual reboot + login, with exe in a path containing spaces
- [ ] **Tray:** icon shows — verify it survives killing Explorer; verify "pause input" releases held keys
- [ ] **Apps list:** shows windows — verify no ghost/UWP-cloaked entries; focus works while *another* app is foreground
- [ ] **Sleep:** PC sleeps — verify it *sleeps* (fast wake), not hibernates
- [ ] **Clipboard:** sync works — verify no ping-pong with auto-sync on both ends and two phones paired
- [ ] **Pairing:** PIN flow works — verify PIN visible when Focus Assist is on; verify lockout message accuracy; verify revoked phone gets clean re-pair flow
- [ ] **Logs:** exist — verify no tokens/PINs/typed text/clipboard contents in them

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Raw-token auth shipped | MEDIUM | Protocol major bump; add challenge-response; phones re-pair once (token stays valid, only wire changes) |
| GestureDetector trackpad shipped | MEDIUM | Rewrite trackpad surface on `Listener`; rest of app untouched if controller layer is clean |
| Full-snapshot `text` schema shipped | MEDIUM | New `text` op-based message + version negotiation; keep old handler during transition |
| Nagle discovered late | LOW | Set `TCP_NODELAY` both sides; Dart side may require swapping WebSocket construction path |
| Stuck-key reports | LOW | Add held-state map + release-on-close to dispatcher; ship server update only |
| Discovery failures in the wild | LOW | Manual IP entry (if built) is the immediate user workaround; per-interface broadcast in next server build |
| Sleep-hibernates shipped | LOW | Swap executor to `SetSuspendState`; server-only fix |
| Tray icon lost on Explorer restart | LOW | Handle `TaskbarCreated`; server-only fix |

## Pitfall-to-Phase Mapping

Phase names are suggested groupings for the roadmap; map to actual phases when they exist.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 9. Plaintext token / auth design | Protocol design (schemas + fixtures) | Fixture review: no raw token in any post-pairing message; replay test in integration suite |
| 11 (schema half). Text as diff-ops | Protocol design | Fixtures include autocomplete-revision + emoji cases |
| 3. Nagle / TCP_NODELAY | Transport foundation | Integration test asserts nodelay; latency overlay on real WiFi < 30ms |
| 12 (hook half). Session-cleanup hook | Transport foundation (dispatcher) | Mock-executor test: disconnect mid-drag → releases injected |
| 2. Delta scaling / DPI | Core input (trackpad) | Two phones + two DPI settings feel identical per checklist |
| 4. Gesture classification / hot path | Core input (trackpad) | Small-nudge responsiveness; DevTools rebuild audit during use |
| 1. UIPI awareness | Core input (server executor) | Manual: Task Manager (admin) focused → phone shows status, not silence |
| 11 (client half). IME diffing | Keyboard feature | Gboard autocomplete/swipe/emoji manual pass |
| 6. Discovery robustness | Discovery & pairing | Multi-adapter PC, hotspot, Public-profile network matrix; manual-IP fallback exists |
| 9 (lockout). Global lockout | Discovery & pairing | Unit test: failures from rotating IPs still lock |
| 7. Clipboard loops + Android 10 scoping | Clipboard feature | Auto-sync soak test (idle 10 min, no traffic); feature copy reviewed against Android 10 reality |
| 10. Power/apps Win32 realities | Control-center features (flag for phase-level research/spike: apps.focus + EnumWindows filtering) | Sleep-vs-hibernate check; focus-from-background check; window-list ghost audit |
| 5. Lifecycle reconnect + WiFi lock | Connection polish | Resume-to-connected < 2s; battery latency soak |
| 8. Autostart/tray traps | Server platform (tray/autostart) — threading model set in first server scaffold | Reboot test; Explorer-kill test; spaces-in-path test |

## Sources

- Microsoft Learn — [UIPI / UIAccess elevation rules](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/user-account-control-only-elevate-uiaccess-applications-that-are-installed-in-secure-locations), [SendInput to elevated windows discussion](https://microsoft.public.platformsdk.security.narkive.com/s9A4mRUQ/how-to-proper-use-sendinput-to-a-elevated-window-from-a-service), [Mouse input scaling on high-DPI](https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/mouse-input-incorrectly-scaled), [Relative mouse movement](https://learn.microsoft.com/en-us/windows/uwp/gaming/relative-mouse-movement), [Windows Firewall UDP rule blocking](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/windows-fireware-rule-block-udp-communication) — HIGH
- enigo — [docs.rs (DPI awareness note)](https://docs.rs/enigo/latest/x86_64-pc-windows-msvc/enigo/index.html), [GitHub issues incl. #140 keyboard no-op, #38 slow text, #201 modifier interruption](https://github.com/enigo-rs/enigo/issues) — MEDIUM-HIGH
- Android Developers — [Foreground service types required (Android 14)](https://developer.android.com/about/versions/14/changes/fgs-types-required), [FGS types incl. connectedDevice/dataSync 6h limit](https://developer.android.com/develop/background-work/services/fgs/service-types) — HIGH
- Doze/keep-alive — [Google Issue Tracker 37070074](https://issuetracker.google.com/issues/37070074), [Qt forum Doze keep-alive thread](https://forum.qt.io/topic/90939/sending-keep-alive-messages-on-android-even-if-the-device-is-in-sleep-doze-mode) — MEDIUM
- Discovery failures — [Mirror networking Android multicast lock issue #2878](https://github.com/vis2k/Mirror/issues/2878), [Thali: UDP broadcast disabled on screen-off #1620](https://github.com/thaliproject/Thali_CordovaPlugin/issues/1620), [UniFi broadcast management](https://help.ui.com/hc/en-us/articles/27384925962647-Managing-Broadcast-Traffic-with-UniFi) — MEDIUM-HIGH
- Flutter — [PointerEventResampler](https://api.flutter.dev/flutter/gestures/PointerEventResampler-class.html), [onPanUpdate lag #54359](https://github.com/flutter/flutter/issues/54359), [trackpad gesture breaking change](https://docs.flutter.dev/release/breaking-changes/trackpad-gestures), [gestures architecture](https://docs.flutter.dev/ui/interactivity/gestures) — HIGH
- tray-icon — [docs.rs event-loop requirements](https://docs.rs/tray-icon/latest/tray_icon/), [Rust forum: combining event loops with tokio](https://users.rust-lang.org/t/launch-other-event-loop-without-blocking-current/101048) — MEDIUM-HIGH
- Clipboard fragility — [rdpclip deadlock analysis](https://prunelab.net/blog/rdp-clipboard-fix), [FreeRDP clipboard issue #11276](https://github.com/FreeRDP/FreeRDP/issues/11276) — MEDIUM
- Design-spec cross-analysis (sleep via shutdown.exe, plaintext `auth`, client-only modifier reset): `docs/superpowers/specs/2026-07-07-remote-control-design.md` — HIGH (direct reading)

---
*Pitfalls research for: phone-as-remote-input (Flutter Android + Rust Windows)*
*Researched: 2026-07-07*
