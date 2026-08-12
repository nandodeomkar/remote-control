# Phase 3: Discovery, Pairing & Connection - Context

**Gathered:** 2026-07-08
**Status:** Ready for planning

<domain>
## Phase Boundary

The phone finds the PC on the LAN, pairs once with a PIN, and from then on connects and recovers silently. Delivers the ConnectionService layer: UDP beacon listener → live device list (name + IP, machine-GUID disambiguated), PIN pairing flow with clear expiry/attempt/lockout errors, silent challenge-response reconnect with the token in secure storage, automatic recovery from WiFi drops and PC IP changes (exponential backoff + beacon re-listen + instant retry on app resume), manual IP:port fallback, and live connection status + latency in the app header (CONN-01..CONN-06).

Also the cleanup boundary for Phase-2 spike scaffolding per D-09: in-memory token → persisted secure storage, manual-IP-only screen → device list with manual entry as fallback, debug latency HUD → header latency display, app-wide cleartext → scoped network-security-config.

**Out of scope:** trackpad/keyboard feel work (Phase 4), control-center features (Phases 5–6), tray settings/revoke UI on the server (Phase 7 — but the server must SHOW the pairing PIN via a Windows notification this phase, per roadmap criterion 2), dashboard home identity (Phase 7).

</domain>

<decisions>
## Implementation Decisions

User was offered all four gray areas (connect flow on launch, drop/failure UX, multi-PC memory, spike cleanup scope) and answered "no preference" — all four delegated to Claude's discretion. Defaults locked below so downstream agents don't re-litigate.

### Connect flow on launch
- **D-01:** App launch **auto-reconnects to the last-connected paired PC** (silent challenge-response, no user action). If there is no remembered device or the quick attempt fails, land on the **device list**.
- **D-02:** The device list is the home of this phase's UX: discovered PCs appear live from the beacon listener (name, IP; GUID disambiguates duplicate names); remembered-but-currently-undiscovered devices show grayed with last-known address. Tap a paired device → silent connect; tap an unpaired device → PIN pairing flow.
- **D-03:** Manual IP:port entry (CONN-05) survives as a **secondary affordance from the device list** ("Connect by IP"), not the primary screen. It reuses the existing connect path; a successful manual connection is remembered like a discovered one.

### Drop/failure UX
- **D-04:** Reconnection is **non-blocking**: the app header shows connection state (connected / reconnecting / disconnected) plus live latency (CONN-06). During drops an unobtrusive "Reconnecting…" banner appears; input surfaces stay visible but gated (input disabled until Authed — the Phase-2 gating pattern). A manual "Retry now" affordance is available.
- **D-05:** **Transport failures retry; auth failures stop.** Exponential backoff applies only to socket/network failures. A definitive auth rejection (`authFail` noPairing/badMac — revoked or stale token) terminates silent retry and returns the user to pairing with a plain explanation ("This PC no longer recognizes this phone — pair again"), per roadmap criterion 3. No silent retry loop on auth failures.
- **D-06:** Backoff parameters are planner/researcher discretion (exponential with a cap around 30s). Locked triggers that reset/short-circuit backoff: app resume → instant retry; beacon sighting of the target device → immediate attempt (handles PC IP changes).

### Multi-PC memory
- **D-07:** **Multiple paired PCs supported from the start.** Storage is a map keyed by machine GUID → {device name, auth token, last-known IP:port}. The device list doubles as the switcher. One active session at a time (no simultaneous connections). Rationale: the spec's GUID disambiguation and the server's paired-device list already imply multi-device; doing it now avoids a storage migration later. Tokens live in flutter_secure_storage; non-secret device metadata may live in shared_preferences (stack rule: secrets only in secure storage).

### Spike cleanup scope (D-09 from Phase 2)
- **D-08:** The **latency probe survives as the engine** behind the header's live latency display (CONN-06). The spike's debug HUD overlay widget is removed; its interleaved-ping probe and p50/p95 logic are reused, restyled into the header status chip.
- **D-09:** The **PIN moves to its real home**: the server shows the pairing PIN via a **Windows notification** (roadmap criterion 2). Console printing stays as a dev-visible fallback, no longer the primary path. Notification mechanism (win32 toast vs tray balloon — tray-icon proper is Phase 7) is researcher/planner discretion.
- **D-10:** The **in-memory token is replaced** by flutter_secure_storage persistence (spec-locked). Android **app-wide `usesCleartextTraffic` is replaced by a scoped network-security-config** permitting cleartext ws:// to LAN/private ranges only (carried Phase-3 item from 02-03).

### Claude's Discretion
- All decisions above are Claude-discretion defaults (user had no preference). Planner may refine details (exact screen composition, backoff constants, notification API, storage schema) as long as the observable contract holds: auto-reconnect to last PC with device-list fallback, live beacon-driven device list with manual-IP fallback, transport-retry/auth-stop policy with the revoked-token explanation, multi-PC GUID-keyed memory, latency probe reused for the header, PIN via Windows notification, secure-storage token, scoped cleartext config.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design spec (authoritative)
- `docs/superpowers/specs/2026-07-07-remote-control-design.md` §4 — discovery + pairing: beacon every 2s (device name, machine GUID, port, protocol version), PIN flow, token issue/storage, challenge-response reconnect. Approved and locked — planning must follow it.
- `protocol/SPEC.md` — wire contract (frozen in Phase 1): handshake families (`hello`/`pin`/`pairOk`/`challenge`/`auth`/`authOk`/`authFail` + enumerated authFail reasons), PIN rules (60s expiry, 5 attempts, 5-min per-IP lockout, 20-attempt global cap), replay-defense notes. Discovery beacon is explicitly out of this doc — §4 of the design spec owns it.

### Phase 1–2 foundation (build directly on these)
- `.planning/phases/02-end-to-end-cursor-spike/02-CONTEXT.md` — D-09 spike-removables list this phase cleans up
- `.planning/phases/02-end-to-end-cursor-spike/02-03-SUMMARY.md` — client handshake FSM + driver + latency probe + trackpad screen: the exact assets Phase 3 extends
- `.planning/phases/02-end-to-end-cursor-spike/02-04-GATE-RESULT.md` — transport locked (ws:// + TCP_NODELAY, p95 10ms); no transport rework in this phase
- `app/remote_control/lib/net/handshake_fsm.dart` + `lib/net/handshake.dart` — pure FSM + driver pattern; Phase 3's ConnectionService wraps these, does not rewrite them
- `app/remote_control/lib/net/connection_service.dart` — connectNoDelay TCP_NODELAY construction (proven at the gate) — reuse verbatim
- `app/remote_control/lib/hud/latency_probe.dart` — probe engine reused for the header latency chip (D-08)
- `server/server-core/src/auth/` — PIN lifecycle, token hashing, challenge-response already enforced server-side; Phase 3 adds no server auth logic, only PIN display (notification) and the beacon broadcaster

### Research (domain pitfalls & stack)
- `.planning/research/PITFALLS.md` — Android UDP broadcast reception variance (device-specific; MulticastLock + manual IP are the mitigations — test on owner's device early, carried STATE concern)
- `.planning/research/STACK.md` — `dart:io RawDatagramSocket` for the beacon listener (no package), flutter_secure_storage v10 caveats, wakelock/shared_preferences conventions
- `.planning/research/ARCHITECTURE.md` — component boundaries, data flow

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `HandshakeFsm` + `HandshakeDriver` (`lib/net/`): complete pair + reconnect + all-failure-branches FSM mirroring `session.rs` — ConnectionService composes these; the reconnect FSM wraps around them (connection lifecycle), it does not duplicate handshake states.
- `connectNoDelay` (`lib/net/connection_service.dart`): gate-proven TCP_NODELAY WebSocket construction — every connection this phase makes goes through it.
- `LatencyProbe` (`lib/hud/latency_probe.dart`): interleaved-ping p50/p95 engine — becomes the header latency source (D-08); only the debug HUD widget dies.
- `server-core` auth stack: PIN expiry/attempts/lockout and challenge-response fully tested in Phase 1 — server-side Phase 3 work is the UDP beacon broadcaster + PIN notification display, both in `server-windows`.

### Established Patterns
- Pure IO-free FSM + thin IO driver (Phase 2 pattern) — the reconnect FSM should follow it: transitions unit-tested without sockets, driver does IO.
- Effect objects (NeedPin/Paired/Failed) carry FSM decisions to UI without the FSM importing Flutter — extend for connection-state effects.
- Single channel-stream listener decoding each frame once, routing by family — ConnectionService inherits this; no double-subscribe.
- Riverpod 3 unified Notifier for app state; `#0E0F12` dark-minimal theme.

### Integration Points
- `trackpad_screen.dart` currently owns connect UI (manual IP field + PIN dialog) — Phase 3 extracts connection UX into its own screens/service; trackpad becomes a consumer of ConnectionService state.
- `server-windows/src/main.rs` composition root — gains the UDP beacon broadcast task (tokio interval) and PIN-notification hook.
- `AndroidManifest.xml` — cleartext flag swap to scoped network-security-config; beacon listener may need MulticastLock (Android quirk — research flag).
- Machine GUID source: `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` via winreg (stack doc).

</code_context>

<specifics>
## Specific Ideas

No specific requirements — user delegated all implementation choices. The defaults above (auto-reconnect + device-list fallback, non-blocking reconnect UX, multi-PC GUID-keyed memory, probe-powered header latency) stand as the working contract.

</specifics>

<deferred>
## Deferred Ideas

- Server tray icon, settings window, paired-device revoke UI — Phase 7 (this phase only adds the PIN notification + beacon broadcaster to `server-windows`).
- Trackpad sensitivity/acceleration and gesture set — Phase 4.
- TLS / channel binding for MITM defense — explicitly out of v1 threat model (protocol SPEC residual-risk note).

### Reviewed Todos (not folded)
- "Absolute pointer injection so slow drags survive Windows pointer acceleration" — keyword-matched Phase 3 (score 0.6) but is server input-fidelity work; kept pending for Phase 4 (Trackpad & Keyboard).

</deferred>

---

*Phase: 3-Discovery, Pairing & Connection*
*Context gathered: 2026-07-08*
