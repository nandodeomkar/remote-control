---
phase: 03-discovery-pairing-connection
plan: 01
subsystem: server-discovery
tags: [rust, udp-broadcast, beacon, winrt-toast, winreg, tdd, fixtures]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    provides: "SERVER_PROTO_VERSION in session.rs + fixture harness conventions (fixtures.rs path idiom, drop-marker convention)"
  - phase: 02-end-to-end-cursor-spike
    provides: "server-windows composition root (numbered-step main.rs, RC_PORT override pattern, WR-01 PIN refresh loop)"
provides:
  - "protocol/BEACON.md wire contract + 6 shared fixtures (01-02 decode, 03-06 drop) for the 03-04 Dart decoder"
  - "server_core::transport::beacon — BeaconIdentity, encode_beacon, run_beacon (2s per-interface directed broadcast, UDP 17778), BEACON_INTERVAL, DEFAULT_BEACON_PORT"
  - "notify.rs notify_pin: console print first, WinRT toast second (POWERSHELL_APP_ID, accepted v1 attribution quirk)"
  - "Composition-root beacon identity: winreg MachineGuid + COMPUTERNAME, RC_BEACON_PORT override, name- GUID fallback"
affects: [03-04 discovery client (decodes beacon fixtures), 03-05 ConnectionService (beacon-driven connect), 03-06 device list (GUID identity)]

# Tech tracking
tech-stack:
  added: [if-addrs 0.15 (server-core), winreg 0.56 (server-windows), tauri-winrt-notification 0.8 (server-windows)]
  patterns: ["beacon payload computed once at task start (identity immutable at runtime), interfaces re-enumerated every tick (adapter churn)", "never-die task loop: let _ = send_to per interface, per-tick errors never kill the task (listener.rs posture)", "PIN secrets discipline: stdout + toast only, tracing::warn! carries no pin (T-03-04)"]

key-files:
  created:
    - protocol/BEACON.md
    - protocol/fixtures/beacon/01-valid.json … 06-missing-guid.json
    - server/server-core/src/transport/beacon.rs
    - server/server-windows/src/notify.rs
  modified:
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/session.rs
    - server/server-core/Cargo.toml
    - server/server-windows/src/main.rs
    - server/server-windows/Cargo.toml

key-decisions:
  - "SERVER_PROTO_VERSION widened private -> pub(crate) and referenced by encode_beacon — proto literal never duplicated"
  - "GUID fallback when the registry read fails: stable id 'name-' + device_name() with a warn, never crash the server over identity"
  - "if-addrs lives in server-core (cross-platform) preserving the zero-Windows-deps invariant; winreg + toast stay in server-windows"

patterns-established:
  - "Beacon wire contract: v/app/name/guid/port/proto, UDP 17778, 2s interval, client-side silent-drop validation (BEACON.md owns discovery — SPEC.md excludes it)"
  - "notify_pin as the single PIN display surface — both begin_pairing call sites route through it"

requirements-completed: [CONN-01, CONN-02]

# Metrics
duration: 15min + human checkpoint
completed: 2026-07-08
---

# Phase 3 Plan 01: Beacon Broadcaster + PIN Toast Summary

**UDP discovery beacon (fixture-locked wire contract, per-interface directed broadcast every 2s on 17778) in server-core, plus the pairing PIN's real home: WinRT toast with console-first fallback, wired at both pairing call sites with winreg GUID + COMPUTERNAME identity**

## Performance

- **Duration:** ~15 min execution (19:36–19:51 IST) + human-verify checkpoint approved next session
- **Completed:** 2026-07-08
- **Tasks:** 3 (TDD RED + GREEN, auto wiring, human-verify checkpoint)
- **Files modified:** 17 across three commits

## Accomplishments

- Beacon wire format locked as a contract: `protocol/BEACON.md` + 6 fixtures shared with the upcoming Dart decoder (01-02 decode-ok, 03-06 silent-drop: wrong app, wrong version, string port, missing guid)
- `run_beacon` broadcasts JSON identity every 2s to every up non-loopback IPv4 interface's subnet-directed broadcast address, re-enumerating interfaces each tick (VPN/WSL adapter churn) with the listener.rs never-die posture
- Payload carries exactly `v/app/name/guid/port/proto` — no-secrets asserted by test (T-03-01)
- `notify_pin` prints the PIN to console FIRST (Focus Assist can suppress toasts), then shows the WinRT toast; toast failure warns generically without the PIN (T-03-04)
- Composition root assembles beacon identity (winreg `MachineGuid`, COMPUTERNAME with "Windows PC" fallback), honors `RC_BEACON_PORT`, and spawns the beacon with the RESOLVED WebSocket port

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): Beacon contract tests + fixtures** - `a56264b` (test) — BEACON.md, 6 fixtures, failing unit tests
2. **Task 1 (GREEN): server-core beacon broadcaster** - `0ee1040` (feat) — beacon.rs implementation, all tests green
3. **Task 2: PIN toast + composition-root beacon spawn** - `5b5bd21` (feat) — notify.rs, main.rs identity + spawn, deps
4. **Task 3: Human-verify checkpoint** — approved by owner: toast + console PIN at startup, fresh PIN re-notified after ~60s unpaired (WR-01 loop through notify_pin)

## Files Created/Modified

- `protocol/BEACON.md` - beacon datagram contract: fields, UDP 17778, 2s interval, ≤512-byte client validation, silent-drop rules, unauthenticated-input threat note
- `protocol/fixtures/beacon/*.json` - 6 fixtures in the name/description/wire/expect shape
- `server/server-core/src/transport/beacon.rs` - BeaconIdentity, encode_beacon, directed_broadcast, run_beacon, constants + 4 unit test behaviors
- `server/server-core/src/transport/mod.rs` - `pub mod beacon` (listener/session stay private)
- `server/server-core/src/transport/session.rs` - SERVER_PROTO_VERSION → pub(crate)
- `server/server-windows/src/notify.rs` - notify_pin (console first, toast via POWERSHELL_APP_ID, Duration::Long)
- `server/server-windows/src/main.rs` - mod notify, both PIN call sites routed, machine_guid()/device_name(), RC_BEACON_PORT, tokio::spawn(run_beacon)
- Cargo.tomls - if-addrs 0.15 (core), winreg 0.56 + tauri-winrt-notification 0.8 (windows)

## Decisions Made

- `SERVER_PROTO_VERSION` widened to `pub(crate)` and referenced — proto version literal exists in exactly one place
- Registry-read failure degrades to a stable `name-<device_name>` GUID with a warning; identity failure never crashes the server
- `if-addrs` placed in server-core (cross-platform), keeping the zero-Windows-deps invariant; Windows-only crates isolated in server-windows

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. Toast attribution to "Windows PowerShell" is the documented accepted v1 quirk (proper AUMID registration lands with the Phase-7 tray).

## User Setup Required

None.

## Next Phase Readiness

- Wave 1 complete (03-01, 03-02, 03-03) — wave 2 (03-04: Dart beacon listener + discovery UI) unblocked
- Dart decoder consumes `protocol/fixtures/beacon/` directly; validation rules documented in BEACON.md
- On-phone beacon reception is the carried Phase-3 concern (Android UDP broadcast varies by device) — 03-04 tests on the owner's Xiaomi early; MulticastLock + manual IP entry are the mitigations

## Verification Results

- `cargo build -p server-windows` — success
- `cargo test --workspace` — green (91 + 4 + 8 + 3 passed, 0 failed; includes 4+ beacon unit tests)
- `grep -c "pub mod beacon" transport/mod.rs` = 1; `if-addrs` in server-core only
- Both PIN call sites call `notify_pin` (main.rs:67, main.rs:90); no PIN println remains; warn! carries no pin
- `RC_BEACON_PORT` override present (main.rs:126); `run_beacon` spawned once (main.rs:132)
- Human checkpoint: **approved** — toast + console PIN visible at startup, 60s refresh re-notifies through the same path

## Self-Check: PASSED

- `protocol/BEACON.md` — FOUND
- `server/server-core/src/transport/beacon.rs` — FOUND
- `server/server-windows/src/notify.rs` — FOUND
- Commits `a56264b`, `0ee1040`, `5b5bd21` — FOUND

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-08*
