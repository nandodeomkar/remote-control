---
phase: 07-server-shell-dashboard-polish
plan: 06
subsystem: infra
tags: [rust, windows, winit, tray-icon, muda, egui, uipi, firewall, tray-daemon]

# Dependency graph
requires:
  - phase: 07-03
    provides: "firewall::{inbound_allowed,classify_bind_error}, notify::notify_firewall_warning — the read-only self-test primitives this plan's startup sequence calls"
  - phase: 07-04
    provides: "input_thread::foreground_blocked() — the proactive UIPI detection primitive this plan debounces and wires to a watch epoch"
  - phase: 07-05
    provides: "ServerDeps.conn_count/revoke/blocked transport seams (proto 1.3) this plan's real producers now drive end-to-end"
provides:
  - "shell::{ShellCtx, spawn_shell_thread, UserEvent} — a dedicated winit 0.30 tray-daemon thread coexisting with #[tokio::main]"
  - "shell::tray::{Tray, TrayState} — TrayIcon + muda Pause/Quit menu, programmatic RGBA icon states, device-COUNT-only tooltip"
  - "input_thread::run_input_thread's blocked_tx param — debounced SRV-05 UIPI epoch push from the Move/Click hot path"
  - "main.rs startup firewall/bind self-test (SRV-04/D-06) — AddrInUse and BlockedNoRule both produce a loud toast instead of a crash or silence"
affects: [07-08 (settings window shares this winit loop; consumes ShellCtx.auth/revoke_tx/config/autostart/notify_firewall), 07-07 (config.rs will retype ShellCtx.config from its () placeholder)]

# Tech tracking
tech-stack:
  added: ["tray-icon 0.24", "winit 0.30 (pinned, not the 0.31 beta)", "egui 0.35", "egui-winit 0.35", "egui_glow 0.35"]
  patterns:
    - "Dedicated shell thread (SHARED-D): winit EventLoop::with_any_thread(true) off the tokio main thread, tray built lazily on StartCause::Init, tokio<->shell bridged by an EventLoopProxy<UserEvent> plus tokio::sync::watch channels"
    - "Programmatic RGBA tray icons (Icon::from_rgba solid circles) instead of a bundled .ico asset — zero build-time icon pipeline, reuses the D-12 locked Flutter palette for visual consistency"
    - "Time+transition double-debounced hot-path Win32 probe (UIPI 250ms interval + false->true edge only) protecting the <30ms cursor-latency budget from a per-frame OpenProcess/OpenProcessToken chain"

key-files:
  created:
    - server/server-windows/src/shell/mod.rs
    - server/server-windows/src/shell/tray.rs
    - server/rust-toolchain.toml
  modified:
    - server/server-windows/src/main.rs
    - server/server-windows/src/input_thread.rs
    - server/server-windows/Cargo.toml

key-decisions:
  - "tray-icon 0.24 auto-handles TaskbarCreated re-registration internally (confirmed by reading the vendored source's tray_proc handler, not just trusting RESEARCH's [ASSUMED] A1) — no manual rebuild()/re-register API was implemented; the tray survives an Explorer restart as long as the shell thread keeps pumping its message loop, which it does for the process lifetime"
  - "rustc toolchain pinned to 1.97.0 via a new server/rust-toolchain.toml — the previously-active 1.89 default hard-failed the build because egui/ecolor/emath/epaint 0.35 require rustc >= 1.92 (Rule 3 blocking fix, not a package-legitimacy concern: the crates themselves were exactly the RESEARCH-locked versions)"
  - "UIPI foreground-integrity probe is debounced by BOTH a 250ms time interval AND a false->true transition (not just the transition the plan's literal wording specified) — foreground_blocked() walks two OpenProcess/OpenProcessToken/GetTokenInformation chains per call, too costly to run unthrottled on every Move event at 60-120Hz without risking the locked <30ms cursor-latency budget (PAD-05); this is a Rule 2 addition, not a plan deviation from the debounce requirement itself"
  - "ShellCtx.config and ShellCtx.autostart are typed () placeholders, not stub structs — 07-07 has not landed config.rs yet, and the existing autostart.rs primitives are free functions needing no handle state, so a placeholder type is more honest than inventing a handle shape those later plans would just replace"
  - "Task 2 (channel/ShellCtx/spawn wiring) and Task 3 (firewall self-test) landed in ONE commit — firewall_status is computed in Task 3's bind/inbound-check section and consumed by Task 2's ShellCtx assembly in the same compiling unit; splitting them would leave an intermediate commit that fails cargo build --workspace (07-05 Task1+2 precedent)"

patterns-established:
  - "SHARED-D extended to a non-mpsc-poll shape: the shell thread breaks the dedicated-OS-thread mold (a winit event loop instead of an mpsc recv_timeout poll) but its spawn/channel-handoff idiom is identical to the other four dedicated threads in main.rs"

requirements-completed: [SRV-01, SRV-04, SRV-05]

# Metrics
duration: ~50min
completed: 2026-07-13
---

# Phase 7 Plan 06: Tray Shell + Startup Firewall Self-Test + UIPI Wiring Summary

**A dedicated winit 0.30 thread (with_any_thread) hosts a tray-icon system tray with a device-count tooltip, Pause/Quit menu, and three programmatic RGBA icon states, coexisting with the existing `#[tokio::main]` composition root; main.rs now catches bind AddrInUse and runs a read-only Windows Firewall inbound check at startup (both surface a loud toast instead of crashing or staying silent), and the input thread pushes a time+transition-debounced UIPI-blocked epoch that the tray/session layer can react to.**

## Performance

- **Duration:** ~50 min (includes a `cargo fetch`/toolchain-upgrade detour: egui 0.35 required bumping the pinned rustc from 1.89 to 1.97)
- **Completed:** 2026-07-13
- **Tasks:** 3 (Task 2 + Task 3 landed in one commit — see Decisions Made)
- **Files modified:** 6 (3 created, 3 modified)

## Accomplishments
- `shell/tray.rs` — `Tray` (`TrayIcon` + `muda` Pause/Quit menu), `TrayState` (Normal/Paused/Warning) rendered as programmatically-generated solid-circle RGBA icons in the D-12 locked palette (accent blue / muted gray / error red) — no bundled `.ico` asset needed. `set_tooltip(count)` shows the device COUNT only, never names (T-07-20).
- `shell/mod.rs` — `ShellCtx` (all fields defined interface-first) + `spawn_shell_thread(ctx) -> EventLoopProxy<UserEvent>`: a `std::thread` running `EventLoop::<UserEvent>::with_user_event().with_any_thread(true)`, tray built on `StartCause::Init` (never at spawn — Pitfall 3), `TrayIconEvent`/`MenuEvent` forwarded via the proxy, Pause toggles `pause_tx` + flips the icon, Quit exits the process.
- Verified (by reading the vendored `tray-icon` 0.24.1 source, not just trusting the RESEARCH assumption) that `TaskbarCreated` re-registration is handled internally by the crate — no manual rebuild path was needed.
- `main.rs`: real `pause_tx`/`revoke_tx`/`blocked_tx` replace all three 07-05 interim `_`-prefixed producers; `conn_count`'s `Arc<Sender>` gains a tokio forwarding task pushing every change to the shell thread's tooltip via the `EventLoopProxy`.
- `main.rs` SRV-04/D-06: bind `AddrInUse` now routes through `firewall::classify_bind_error` into a `warn!` + `notify_firewall_warning` toast instead of `?`-propagating into a crash; a successful bind runs `firewall::inbound_allowed(port)` and fires the loud `BlockedNoRule` toast (an inconclusive `Unknown` stays fail-quiet, per `firewall.rs`'s documented contract).
- `input_thread.rs`: `run_input_thread` grows a `blocked_tx: watch::Sender<u64>` param; `maybe_check_uipi` debounces `foreground_blocked()` (07-04) by both a 250ms interval and a false→true transition, called from the `Move`/`Click` arms.
- `cargo build --workspace` clean; `cargo test --workspace` green (99 lib + 7 fixture + 22 integration + 25 server-windows unit, 3 `#[ignore]`d on-device-only tests).

## Task Commits

Each task was committed atomically (Task 2 + Task 3 combined — see Decisions Made):

1. **Task 1: shell thread — winit 0.30 loop + tray on Init + tooltip/pause/quit + Explorer-restart** - `65072ad` (feat)
2. **Task 2 + Task 3: main.rs composition-root wiring + startup firewall self-test** - `d04e397` (feat)

## Files Created/Modified
- `server/server-windows/src/shell/mod.rs` (new) - `ShellCtx`, `spawn_shell_thread`, `UserEvent`, `ShellApp` (the `ApplicationHandler` driving the tray).
- `server/server-windows/src/shell/tray.rs` (new) - `Tray`, `TrayState`, programmatic RGBA icon generation, device-count-only tooltip text.
- `server/rust-toolchain.toml` (new) - pins the workspace to rustc 1.97.0 (egui 0.35's dependency chain requires >= 1.92).
- `server/server-windows/src/main.rs` (modified) - real conn_count/pause/revoke/blocked producers, bind-error classification, firewall self-test, `ShellCtx` assembly, `spawn_shell_thread` call, conn_count→tooltip forwarding task.
- `server/server-windows/src/input_thread.rs` (modified) - `run_input_thread(rx, blocked_tx)`, `maybe_check_uipi` debounce helper, `UIPI_CHECK_INTERVAL` const; `foreground_integrity_rid`/`our_integrity_rid`/`foreground_blocked` lose their 07-04 `allow(dead_code)`.
- `server/server-windows/Cargo.toml` (modified) - `tray-icon = "0.24"`, `winit = "0.30"`, `egui`/`egui-winit`/`egui_glow = "0.35"`.

## Decisions Made
- TaskbarCreated re-registration: confirmed via source read (not assumption) that tray-icon 0.24 handles it internally — see key-decisions above.
- rustc toolchain bump to 1.97.0 via a new `rust-toolchain.toml` — required by egui 0.35's dependency chain, unrelated to any package-legitimacy concern (the crate versions are exactly RESEARCH-locked).
- UIPI probe gets a 250ms time-based throttle in addition to the plan-specified transition debounce, to protect the hot mouse-move path's latency budget.
- `ShellCtx.config`/`ShellCtx.autostart` are `()` placeholders rather than invented handle types, since neither 07-07's config nor a stateful autostart handle exists yet.
- Task 2 + Task 3 commits combined (compilation-order dependency) — see key-decisions above.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Pinned the workspace rustc toolchain to 1.97.0**
- **Found during:** Task 1 (`cargo build -p server-windows` after adding the egui/winit/tray-icon deps)
- **Issue:** The environment's default rustc (1.89.0) is below the `>= 1.92` floor egui/ecolor/emath/epaint 0.35 require; the build hard-failed with a version-gate error before any of this plan's code even compiled.
- **Fix:** Added `server/rust-toolchain.toml` pinning `channel = "1.97.0"` (the then-current stable release, already fetched via `rustup toolchain install stable`).
- **Files modified:** `server/rust-toolchain.toml` (new)
- **Verification:** `cargo build -p server-windows` / `cargo build --workspace` both clean under the pinned toolchain.
- **Committed in:** `65072ad` (Task 1 commit)

**2. [Rule 2 - Missing Critical] Added a 250ms time-based throttle to the UIPI foreground probe**
- **Found during:** Task 2 (wiring `run_input_thread`'s `blocked_tx`)
- **Issue:** The plan's literal instruction ("in the Move/Click arms, call `foreground_blocked()` ... debounce [only advance the epoch on a transition]") debounces the SEND but not the Win32 PROBE itself — `foreground_blocked()` walks two full `OpenProcess`/`OpenProcessToken`/`GetTokenInformation` chains, which is too expensive to run unthrottled on every `Move` event at typical 60-120Hz trackpad rates without risking the locked <30ms cursor-latency budget (PAD-05).
- **Fix:** Added `maybe_check_uipi()` with a `UIPI_CHECK_INTERVAL` (250ms) time gate wrapping the existing transition-debounce logic — the probe itself now runs at most 4x/sec regardless of move-event frequency, while the transition/epoch-push semantics are unchanged.
- **Files modified:** `server/server-windows/src/input_thread.rs`
- **Verification:** `cargo test -p server-windows input_thread` green (existing UIPI predicate/accumulator tests unaffected — `maybe_check_uipi` is new, untested pure-timing glue with no independently-testable behavior beyond what `is_blocking_il`/`foreground_blocked` already cover).
- **Committed in:** `d04e397` (Task 2+3 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking toolchain fix, 1 missing-critical perf safeguard). No scope creep — both are necessary for the plan's own stated build-success and latency-budget constraints.
**Impact on plan:** All three artifacts, both key_links (conn_count→tooltip, foreground_blocked→blocked watch), and every acceptance grep landed as specified.

## Issues Encountered
- `egui-glow` is the crates.io package name (underscore, not the hyphenated `egui-glow` guessed from the plan's Cargo.toml install-block prose) — `cargo fetch` immediately surfaced the correct name via its "perhaps you meant" suggestion; a one-line Cargo.toml fix, not a deviation worth its own entry.

## User Setup Required
None — no external service configuration required. On-device validation (tray icon presence, `taskkill /f /im explorer.exe && start explorer` icon-return, Pause toggling input, Quit exiting, a firewall-blocked port showing the warning + toast) is deferred to the phase gate per the plan's `<verification>` section.

## Next Phase Readiness
- **07-07 (config persistence):** can retype `ShellCtx.config` from its `()` placeholder to a real config handle once `config.rs` lands.
- **07-08 (settings window):** shares this exact winit loop (egui-on-winit, not `eframe` — RESEARCH Pitfall 4) and consumes `ShellCtx.auth`/`revoke_tx`/`autostart`/`notify_firewall`, all already threaded through and currently `#[allow(dead_code)]`-scoped pending that plan.
- The tray/winit/tokio topology (the phase's single riskiest novel piece, per RESEARCH Open Q2) is proven buildable and passes the full automated suite; only the on-device Explorer-restart/pause/quit/firewall-toggle checks remain, at the phase gate.
- No blockers.

## Self-Check: PASSED

- FOUND: `server/server-windows/src/shell/mod.rs`
- FOUND: `server/server-windows/src/shell/tray.rs`
- FOUND: `server/rust-toolchain.toml`
- FOUND commit: `65072ad` (Task 1)
- FOUND commit: `d04e397` (Task 2+3)
- `cargo build --workspace` clean; `cargo test --workspace` green (99 lib + 7 fixture + 22 integration + 25 server-windows, 3 ignored on-device-only); `cargo test -p server-windows firewall` green (3 passed, 1 ignored).

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-13*
