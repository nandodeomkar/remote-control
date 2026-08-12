---
phase: 07-server-shell-dashboard-polish
plan: 07
subsystem: server-config
tags: [rust, server-windows, toml, dirs, serde, persistence, pairing, smart-startup, revoke]

# Dependency graph
requires:
  - phase: 07-01
    provides: "AuthManager Vec<PairedDevice> store: from_paired, paired_records, changes() watch signal, revoke, complete_pairing_named"
  - phase: 07-05
    provides: "ServerDeps.revoke (watch::Receiver<u64>) — the session revoke select! branch this plan's revoke_device epoch bump drives"
  - phase: 07-06
    provides: "ShellCtx carrying the auth Arc + revoke_tx into the shell thread — the handles 07-08's Pair-new/revoke UI will pass to this plan's helpers"
provides:
  - "server-windows/src/config.rs: Config + PairedDeviceCfg serde structs, config_path/load/parse/to_toml/save, to_paired_devices/from_auth hash-hex codec, resolve_port precedence, DEFAULT_PORT"
  - "main.rs: AuthManager::from_paired seed from config.toml (D-01) — pairings survive restarts"
  - "main.rs: smart startup (D-03) — paired => silent, zero => PIN window + bounded WR-01 refresh"
  - "main.rs: begin_on_demand_pairing (D-02) — fresh 60s PIN window any time, for 07-08's Pair-new"
  - "main.rs: revoke_device (D-05) — auth.revoke + revocation-epoch bump for 07-08's settings revoke"
  - "main.rs: auth.changes() subscription task — config.toml re-serialized on every pair/revoke"
  - "clip_thread: sync_enabled AtomicBool gate — config.clipboard_sync stops PC->phone mirror pushes"
affects: [07-08 (settings window consumes begin_on_demand_pairing/revoke_device/config handles), 07-13 (on-device UAT proves persistence across restart)]

# Tech tracking
tech-stack:
  added: [toml 1.1, dirs 6.0 (server-windows; both CLAUDE.md-locked + RESEARCH legitimacy-audit approved), serde derive + hex 0.4 (already in workspace tree)]
  patterns:
    - "Fail-safe config parse (T-07-27/ASVS V5): corrupt file => defaults, bad hash entry => skipped with name-only warn, bad port => field-local None via a lenient toml::Value deserializer (never fails the whole document)"
    - "Pure decision seams for composition-root logic: smart_startup_pin / revoke_device are plain fns unit-tested without tokio/OS (presenter_timer/pct_from_scalar precedent applied to main.rs)"

key-files:
  created:
    - server/server-windows/src/config.rs
  modified:
    - server/server-windows/src/main.rs
    - server/server-windows/Cargo.toml
    - server/server-windows/src/clip_thread.rs
    - server/server-windows/src/shell/mod.rs

key-decisions:
  - "Config::default() sets clipboard_sync: true (manual Default impl, not derive): Phase 6 shipped clipboard auto-sync always-on, so a fresh install with no config.toml must not silently regress it — false-by-default would have disabled a shipped feature"
  - "port deserializes through a lenient toml::Value codec (de_port): a garbage/out-of-range/zero port drops that FIELD to None instead of failing the whole document — a hand-edited port can never nuke the paired list"
  - "resolve_port replaces main.rs's hard-error RC_PORT parse: an invalid env value now warns and falls through to config/default (fail-safe, consistent with T-07-27) instead of aborting startup"
  - "RC_PORT env override is never baked into config.toml: the step-5b save subscription re-serializes cfg.port (the loaded value), not the resolved port"
  - "beacon guid fallback stays COMPUTERNAME-based while the beacon display name uses cfg.device_name: a display-name edit must not change machine identity"
  - "clip-sync gate is an Arc<AtomicBool> moved into run_clip_thread, checked on the poll tick only: clip.set (phone-initiated, explicit user action) keeps working with sync off; 07-08 clones the Arc for its settings toggle"

patterns-established:
  - "Scoped allow(dead_code) hand-off helpers: begin_on_demand_pairing/revoke_device live at the crate root, fully implemented + unit-tested, awaiting their 07-08 shell callers (same precedent as 07-03's autostart/notify_firewall_warning)"

requirements-completed: [SRV-03]

# Metrics
duration: ~15min
completed: 2026-07-14
---

# Phase 7 Plan 07: Config Persistence + Smart Startup Summary

**Paired token hashes now persist fail-safe in `%APPDATA%/RemoteControl/config.toml` (hash hex only, never a raw token) and reload via `AuthManager::from_paired` at startup; smart startup opens a PIN window only when zero devices are paired, `begin_on_demand_pairing`/`revoke_device` expose the 07-08 shell triggers, and an `auth.changes()` subscription re-serializes config on every pair/revoke — closing the one-pairing-per-run todo.**

## Performance

- **Duration:** ~15 min
- **Completed:** 2026-07-14
- **Tasks:** 2 (Task 1 TDD: RED + GREEN commits)
- **Files modified:** 5 (1 created + 4 modified) + Cargo.lock + todo closure

## Accomplishments

- `config.rs` (new, TDD): `Config` + `[[paired]]` `PairedDeviceCfg` serde structs over `toml` 1.1 + `dirs` 6.0 at `dirs::config_dir()/RemoteControl/config.toml`. Load path is fail-safe end to end (T-07-27): corrupt/partial file ⇒ `Config::default()`, malformed hash hex/length ⇒ entry skipped with a name-only warn, garbage/out-of-range port ⇒ field-local `None`, missing fields ⇒ defaults — never a panic. The file stores 64-hex SHA-256 hashes ONLY; no raw-token field exists on any struct, test-asserted (T-07-26).
- `main.rs` seeds `AuthManager::from_paired(config::to_paired_devices(&cfg))` — paired phones survive server restarts (D-01, SRV-03).
- Smart startup (D-03): ≥1 paired ⇒ fully silent (no PIN toast); zero paired ⇒ `begin_pairing()` + `notify_pin`, with the WR-01 re-pin refresh loop now spawned ONLY on that branch (the permanent process-lifetime loop is gone). Decision extracted into the pure `smart_startup_pin` fn, unit-proven both ways.
- On-demand pairing (D-02): `begin_on_demand_pairing(&auth)` opens a fresh 60s PIN window any time — including when devices are already paired (multi-device) — for 07-08's tray/settings "Pair new device".
- Config re-serialization (D-01/D-05): a tokio task subscribes to `auth.changes()` and rewrites config.toml from `paired_records()` on EVERY paired-set mutation — pairings AND revokes both persist immediately.
- Revoke wiring (D-05): `revoke_device(&auth, &revoke_tx, hash)` removes the hash, and iff removed advances the revocation epoch so the 07-05 session branch drops the live connection; the change-signal bump independently saves config. Unit-proven (present hash ⇒ both signals; absent hash ⇒ neither).
- Port precedence `RC_PORT` env > `config.port` > `DEFAULT_PORT` (17777) via `config::resolve_port`; device name resolution `cfg.device_name` > `COMPUTERNAME` feeds the beacon.
- `clipboard_sync` gate (RESEARCH Open Q5): `run_clip_thread` grew an `Arc<AtomicBool>` checked on the poll tick — sync off stops PC→phone mirror pushes while phone-initiated `clip.set` keeps working.
- 10 new unit tests (7 config + 3 startup); full `server-windows` suite 35 passed / 2 ignored; `cargo build --workspace` green with zero warnings.

## Task Commits

1. **Task 1 RED: failing config.toml round-trip + fail-safe load tests** - `a95de77` (test)
2. **Task 1 GREEN: config.rs implementation** - `0bac161` (feat)
3. **Task 2: main.rs config seed, smart startup, on-demand pairing, save subscription, revoke wiring, clip gate** - `354fa13` (feat)
4. **Todo closure: one-pairing-per-run moved to done/** - `10b2143` (docs)

## TDD Gate Compliance

Task 1 (`tdd="true"`): RED gate `a95de77` (7 tests failing on `todo!()` bodies, verified failing before implementation) → GREEN gate `0bac161` (all 7 passing). No refactor commit needed — the GREEN implementation landed clean.

## Files Created/Modified

- `server/server-windows/src/config.rs` - Config/PairedDeviceCfg structs, `config_path`/`load`/`parse`/`to_toml`/`save`, `to_paired_devices`/`from_auth` hash-hex codec, `resolve_port`, `DEFAULT_PORT`; 7 unit tests.
- `server/server-windows/src/main.rs` - step 2b config load + name resolution; step 5 `from_paired` seed; step 5a smart startup + bounded WR-01 refresh; step 5b `changes()` save subscription; `resolve_port` at step 7; beacon name from config; `smart_startup_pin`/`begin_on_demand_pairing`/`revoke_device` helpers; 3 startup tests; local `DEFAULT_PORT` const removed (config.rs owns it).
- `server/server-windows/Cargo.toml` - `serde` (derive), `toml` 1.1, `dirs` 6.0, `hex` 0.4.
- `server/server-windows/src/clip_thread.rs` - `run_clip_thread` grew the `sync_enabled: Arc<AtomicBool>` param gating the poll-tick push.
- `server/server-windows/src/shell/mod.rs` - ShellCtx doc comment updated to name the 07-08 hand-off helpers (doc-only).

## Decisions Made

- `Config::default()` keeps `clipboard_sync: true` via a manual `Default` impl (plan said derive): a derived `false` default would have silently disabled the Phase-6 always-on clipboard sync for every fresh install with no config.toml yet.
- The port field deserializes through a lenient `toml::Value` codec so a hand-edited garbage port drops only that field — a strict `Option<u16>` would have failed the whole document and wiped the paired list to defaults.
- `resolve_port` makes an invalid `RC_PORT` warn-and-fall-through where main.rs previously hard-errored — consistent with the plan's fail-safe-everywhere posture (T-07-27).
- The save subscription re-serializes `cfg.port` (the loaded config value), never the resolved port — the `RC_PORT` env override must not get baked into the file.
- The beacon's guid *fallback* id stays `COMPUTERNAME`-derived while its display *name* uses `cfg.device_name`: renaming the PC in settings must not change discovery identity.
- `smart_startup_pin` and `revoke_device` are pure/plain fns at the crate root so the D-03 and D-05 validation rows are unit tests, not integration scaffolding.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical functionality] `clip_thread.rs` signature change for the clipboard_sync gate**
- **Found during:** Task 2
- **Issue:** The plan's action mandates "pass clipboard_sync from config into the clip-thread gate (or a shared flag the clip.changed push respects — RESEARCH Open Q5)" but `clip_thread.rs` was not in the plan's `files_modified` list. The gate cannot exist without touching the thread that owns the push.
- **Fix:** `run_clip_thread` grew a third param `sync_enabled: Arc<AtomicBool>`, checked only on the poll-tick branch — `ClipCmd::Set` still drains (phone-initiated set stays an explicit user action). Existing clip tests unaffected (they target the pure gate fns).
- **Files modified:** `server/server-windows/src/clip_thread.rs`
- **Commit:** `354fa13`

**2. [Rule 2 - Doc accuracy] `shell/mod.rs` ShellCtx doc comment refresh**
- **Found during:** Task 2
- **Issue:** The ShellCtx doc said "07-07 has not landed config.rs yet" — now false, and 07-08 needs to know the concrete hand-off helper names.
- **Fix:** Doc-only comment update naming `begin_on_demand_pairing`/`revoke_device`; no code change.
- **Files modified:** `server/server-windows/src/shell/mod.rs`
- **Commit:** `354fa13`

---

**Total deviations:** 2 auto-fixed (both direct consequences of the plan's own action text)
**Impact on plan:** No scope creep; no architectural changes.

## Issues Encountered

None — both tasks landed as planned, first verification pass green.

## Known Stubs

- `ShellCtx.config` / `ShellCtx.autostart` remain `()` placeholders (documented interface-first fields; 07-08 retypes them for its settings window). `begin_on_demand_pairing`/`revoke_device` carry scoped `#[allow(dead_code)]` until their 07-08 shell callers land — both are fully implemented and unit-tested, not stubs of behavior. Neither blocks this plan's goal (persistence + smart startup are live end to end).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 07-08's settings window has everything it needs: `ShellCtx.auth` + `crate::begin_on_demand_pairing` (Pair-new), `ShellCtx.revoke_tx` + `crate::revoke_device` (paired-list revoke — config save + live-session drop both automatic), `config::load/save/from_auth` for settings edits, and the clip-sync `AtomicBool` to clone before the thread-spawn move in main.rs.
- Phase gate (07-13 UAT): pair a phone, restart the server, phone reconnects silently — persistence is now testable on-device.
- The one-pairing-per-run pending todo is closed (moved to `todos/done/` with a closure note).
- No blockers.

## Self-Check: PASSED

- FOUND: `server/server-windows/src/config.rs`
- FOUND: `server/server-windows/src/main.rs`
- FOUND: `server/server-windows/src/clip_thread.rs`
- FOUND: `server/server-windows/src/shell/mod.rs`
- FOUND: `.planning/todos/done/2026-07-09-server-one-pairing-per-run.md`
- FOUND commit: `a95de77` (Task 1 RED)
- FOUND commit: `0bac161` (Task 1 GREEN)
- FOUND commit: `354fa13` (Task 2)
- FOUND commit: `10b2143` (todo closure)
- `cargo test -p server-windows` — 35 passed, 2 ignored (on-device-only), 0 failed; `cargo build --workspace` green, zero warnings.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-14*
