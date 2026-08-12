---
phase: 07-server-shell-dashboard-polish
plan: 03
subsystem: infra
tags: [rust, windows, auto-launch, INetFwPolicy2, COM, winreg, firewall, autostart, toast, tauri-winrt-notification]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    provides: "apps_thread.rs COM discipline (CoInitializeEx MTA / .ok()-drop every HRESULT / CoUninitialize) cloned by firewall.rs"
  - phase: 03-discovery-pairing
    provides: "main.rs machine_guid() winreg degrade-never-panic shape mirrored by autostart::is_enabled"
provides:
  - "autostart::{enable,disable,is_enabled} — HKCU Run key toggle over auto-launch with absolute current_exe()"
  - "firewall::inbound_allowed(port) -> FirewallStatus — read-only INetFwPolicy2 inbound check on the active profile"
  - "firewall::classify_bind_error(&io::Error) -> Option<BindProblem::PortInUse> — AddrInUse classifier"
  - "notify::notify_firewall_warning(hint) — loud, secret-free D-06 firewall-block toast"
affects: [07-06 composition-root wiring (startup firewall self-test + autostart at boot), 07-08 settings window (autostart toggle + firewall hint)]

# Tech tracking
tech-stack:
  added: [auto-launch 0.6, "windows feature Win32_NetworkManagement_WindowsFirewall", "windows feature Win32_System_Ole"]
  patterns:
    - "Self-contained OS-integration primitives isolated from main.rs (composition-root churn minimized; #[ignore]-testable against real OS state)"
    - "Short-lived COM apartment for a one-shot read (CoInitializeEx MTA -> fallible query helper -> CoUninitialize iff init.is_ok())"
    - "Scoped #![allow(dead_code)] / #[allow(dead_code)] on intentionally-unwired primitives that a named later plan consumes"

key-files:
  created:
    - server/server-windows/src/autostart.rs
    - server/server-windows/src/firewall.rs
  modified:
    - server/server-windows/src/notify.rs
    - server/server-windows/src/main.rs
    - server/server-windows/Cargo.toml

key-decisions:
  - "Firewall verdict is FirewallEnabled + DefaultInboundAction short-circuit, then read-only INetFwRules enumeration for an enabled inbound Allow rule covering our TCP port — because Windows default inbound action IS Block on standard profiles, so a getters-only heuristic would false-positive BlockedNoRule on every machine that has a valid allow rule"
  - "Rule enumeration matches on port regardless of target program (single-host heuristic, A3): a false-negative on the warning chosen over a nagging false-positive"
  - "VARIANT + IEnumVARIANT required BOTH Win32_System_Ole AND Win32_System_Com features (VARIANT is cfg-gated on all(Com, Ole)); IEnumVARIANT lives in Win32::System::Ole, not ::Com"
  - "inbound_allowed returns Unknown (fail-quiet) on any COM error — the caller must NOT warn on Unknown; an uncertain probe is not evidence of a block"

patterns-established:
  - "Read-only Win32 COM query: fallible query_*() helper returning windows::core::Result, wrapped by a public fn that collapses any Err to a safe default and never panics"
  - "#[ignore] on-device round-trip/smoke tests with guaranteed teardown (autostart disable() before any unwinding assert) live alongside the CI-safe pure unit tests"

requirements-completed: [SRV-02, SRV-04]

# Metrics
duration: 8min
completed: 2026-07-12
---

# Phase 7 Plan 03: Server OS-Integration Primitives Summary

**HKCU autostart toggle (auto-launch), a strictly read-only INetFwPolicy2 inbound-allowed check + AddrInUse bind classifier, and a secret-free firewall-block toast — three self-contained server-windows primitives, no composition-root wiring.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-12T11:50:36Z
- **Completed:** 2026-07-12T11:58:55Z
- **Tasks:** 3
- **Files modified:** 5 (2 created, 3 modified)

## Accomplishments
- `autostart.rs` — `enable`/`disable`/`is_enabled` over `auto-launch`'s `AutoLaunchBuilder`, bound to the ABSOLUTE `current_exe()`, HKCU-only (never HKLM/admin), `is_enabled()` degrades to `false` on any error.
- `firewall.rs` — `inbound_allowed(port) -> FirewallStatus` (Allowed / BlockedNoRule / Unknown) via a short-lived MTA COM apartment on `INetFwPolicy2`, strictly read-only (grep-confirmed no Add/Set/Remove), plus `classify_bind_error` mapping `AddrInUse -> PortInUse`.
- `notify.rs` — `notify_firewall_warning(hint)` cloning `notify_pin`'s toast + `is_err()`->generic-`warn!` shape, carrying no secret.
- Full server-windows suite green: 22 passed, 2 `#[ignore]` (on-device autostart round-trip + firewall smoke).

## Task Commits

Each task was committed atomically:

1. **Task 1: autostart.rs — auto-launch HKCU wrapper** - `022561d` (feat)
2. **Task 2: firewall.rs — read-only inbound check + bind-error classifier** - `a824ef8` (feat)
3. **Task 3: notify.rs — firewall-warning toast** - `ee02630` (feat)

## Files Created/Modified
- `server/server-windows/src/autostart.rs` (new) - HKCU Run-key enable/disable/is_enabled over auto-launch; #[ignore] round-trip test with guaranteed teardown.
- `server/server-windows/src/firewall.rs` (new) - INetFwPolicy2 read-only inbound-allowed query + classify_bind_error + pure port-coverage helper; classify/port unit tests + #[ignore] live smoke test.
- `server/server-windows/src/notify.rs` (modified) - added notify_firewall_warning alongside notify_pin.
- `server/server-windows/src/main.rs` (modified) - `mod autostart;` + `mod firewall;` declarations.
- `server/server-windows/Cargo.toml` (modified) - `auto-launch = "0.6"`; windows features `Win32_NetworkManagement_WindowsFirewall` + `Win32_System_Ole`.

## Decisions Made
- **Firewall heuristic keeps rule enumeration:** a getters-only verdict (FirewallEnabled + DefaultInboundAction) would report `BlockedNoRule` on every standard Windows machine (default inbound action is Block), so the read-only `INetFwRules` walk for a covering inbound Allow rule is required for correctness, not optional polish.
- **Port-only rule match (A3):** matches an allow rule covering our TCP port regardless of which program it targets — a documented single-host false-negative preferred over a false-positive nag.
- **Fail-quiet Unknown:** any COM error returns `Unknown`, and the doc contract tells 07-06 not to warn on it.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added the `Win32_System_Ole` windows feature**
- **Found during:** Task 2 (firewall.rs)
- **Issue:** The plan named only `Win32_NetworkManagement_WindowsFirewall`, but `IEnumVARIANT` (rule enumeration) lives in `Win32::System::Ole`, and `VARIANT` is cfg-gated on `all(Win32_System_Com, Win32_System_Ole)` — the build failed with two unresolved imports until Ole was enabled.
- **Fix:** Added `"Win32_System_Ole"` to the windows crate feature list and corrected the `IEnumVARIANT` import path from `System::Com` to `System::Ole`.
- **Files modified:** server/server-windows/Cargo.toml, server/server-windows/src/firewall.rs
- **Verification:** `cargo build -p server-windows` clean; `cargo test -p server-windows firewall` 3 passed / 1 ignored.
- **Committed in:** `a824ef8` (Task 2 commit)

**2. [Rule 1 - Bug] Scoped `allow(dead_code)` on intentionally-unwired primitives**
- **Found during:** Tasks 1 and 3
- **Issue:** The new `pub` fns are consumed only by 07-06/07-08, so the interim build emitted `dead_code` warnings (not an error, but avoidable noise that would compound across the phase).
- **Fix:** Added a module-scoped `#![allow(dead_code)]` in autostart.rs and firewall.rs and a targeted `#[allow(dead_code)]` on `notify_firewall_warning` (notify.rs stays otherwise-wired via `notify_pin`), each with a comment naming the consuming plan.
- **Files modified:** autostart.rs, firewall.rs, notify.rs
- **Verification:** `cargo build -p server-windows` warning-clean.
- **Committed in:** `022561d`, `a824ef8`, `ee02630`

---

**Total deviations:** 2 auto-fixed (1 blocking build feature, 1 build-hygiene). No scope creep — both keep the primitives compiling and warning-clean without altering behavior.
**Impact on plan:** All three artifacts, both public function sets, and every acceptance grep landed as specified.

## Issues Encountered
- Locating `VARIANT`/`IEnumVARIANT` in windows 0.62: resolved by grepping the vendored crate source, which revealed the `all(Com, Ole)` cfg gate and the `System::Ole` home of `IEnumVARIANT`.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- **07-06 (composition root):** can call `firewall::inbound_allowed(port)` at startup and fire `notify::notify_firewall_warning(hint)` on `BlockedNoRule`, and catch `bind` errors through `classify_bind_error` for a distinct port-in-use warning instead of a crash.
- **07-08 (settings window):** can render an autostart toggle backed by `autostart::{enable,disable,is_enabled}`.
- **On-device gate (07-06):** `cargo test -p server-windows autostart -- --ignored` and `firewall -- --ignored` are runnable to validate the real HKCU round-trip and live firewall query.
- No blockers.

## Self-Check: PASSED

- Created files exist: autostart.rs, firewall.rs.
- notify_firewall_warning present in notify.rs.
- Task commits present: 022561d, a824ef8, ee02630.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-12*
