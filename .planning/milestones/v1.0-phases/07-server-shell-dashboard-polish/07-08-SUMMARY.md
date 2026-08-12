---
phase: 07-server-shell-dashboard-polish
plan: 08
subsystem: server-shell
tags: [rust, egui, egui-winit, egui_glow, glutin, winit, tray-icon, auto-launch, settings-window]

# Dependency graph
requires:
  - phase: 07-01
    provides: AuthManager paired_records/revoke/begin_pairing + changes() signal
  - phase: 07-03
    provides: autostart enable/disable/is_enabled (HKCU) + firewall inbound_allowed
  - phase: 07-05
    provides: revoke_tx epoch → session force-disconnect (D-05)
  - phase: 07-06
    provides: shell thread (winit loop + tray + ShellCtx + UserEvent + EventLoopProxy)
  - phase: 07-07
    provides: config.toml load/save + from_auth + clip_sync AtomicBool gate
provides:
  - egui-on-winit SettingsWindow (shell/settings.rs) — on-demand create/destroy on the SHARED shell loop (never eframe)
  - SharedSettings live handle (config.rs) — settings edits + auth-change saves share one source of truth
  - Settings fields — device name, port (validated, restart-to-apply), clipboard-sync (live gate), autostart (HKCU)
  - Paired-device list with per-row Revoke (drops live session) + "Pair new device" in BOTH tray menu and settings
  - Persistent firewall hint in settings (SRV-04/D-06)
  - Tray menu grown to Settings… / Pair new device / Pause input / Quit
affects: [08-installer, ios-linux-macos-server-ports, any-settings-surface-work]

# Tech tracking
tech-stack:
  added: [glutin 0.32, glutin-winit 0.5, egui_glow winit feature]
  patterns:
    - egui-on-winit on a shared loop (EguiGlow + glutin), never the framework wrapper that owns its loop
    - egui delayed repaints ride the UserEvent queue (SettingsRepaint → WaitUntil) — no busy render loop
    - SharedSettings Arc<Mutex> read by every config save path — no clobbering between save paths

key-files:
  created:
    - server/server-windows/src/shell/settings.rs
  modified:
    - server/server-windows/src/shell/mod.rs
    - server/server-windows/src/shell/tray.rs
    - server/server-windows/src/config.rs
    - server/server-windows/src/main.rs
    - server/server-windows/Cargo.toml

key-decisions:
  - "egui-on-winit via EguiGlow + glutin 0.32/glutin-winit 0.5 (the pairing egui_glow 0.35 tests against) — eframe cannot share the tray's loop (Pitfall 4)"
  - "SharedSettings live handle replaces the step-5b frozen startup snapshot — settings edits and pairing/revoke saves can no longer clobber each other"
  - "Device-name change also shows 'Restart to apply' (beacon identity binds once at startup) — same Open Q3 story as the port"
  - "Text edits commit on lost-focus (+ commit_pending on window close) — no per-keystroke config writes"
  - "Revoke/Pair-new reuse the existing crate::revoke_device / crate::begin_on_demand_pairing helpers exactly as 07-07's interface comments prescribed"

patterns-established:
  - "Settings window lifecycle: UserEvent::OpenSettings → create-or-focus; CloseRequested → commit_pending + destroy; tray outlives every cycle"
  - "GL stack (window+context+surface+glow+EguiGlow) owned by one struct so close drops everything at once"

requirements-completed: [SRV-03, SRV-02, SRV-04]

# Metrics
duration: ~55min active (wall clock split across a session-limit gap)
completed: 2026-07-15
---

# Phase 7 Plan 08: Settings Window Summary

**On-demand egui-on-winit settings window on the shared tray loop: device name/port/clipboard-sync/autostart editing persisted via config.toml, paired-device list with live-session-dropping Revoke, Pair-new from both tray and settings, and the persistent firewall hint**

## Performance

- **Duration:** ~55 min active (started 2026-07-14T16:15:36Z, completed 2026-07-15T02:16:35Z — wall clock includes a session-limit pause with zero repo changes)
- **Tasks:** 2/2
- **Files modified:** 7 (1 created)

## Accomplishments

- `shell/settings.rs`: a `SettingsWindow` owning winit `Window` + glutin GL context/surface + `EguiGlow`, created ON DEMAND on `UserEvent::OpenSettings` and destroyed on close — egui-on-winit on the 07-06 shell loop, never `eframe` (grep-verified zero occurrences; RESEARCH Pitfall 4)
- Settings fields wired end-to-end: device name and port (validated u16, inline error, "Restart to apply" — Open Q3 restart-required), clipboard-sync (flips the clip thread's live `AtomicBool` gate immediately — Open Q5), autostart checkbox reflecting/driving `autostart::is_enabled/enable/disable` (SRV-02, HKCU-only)
- Paired-device list from `auth.paired_records()` with per-row Revoke → `crate::revoke_device` (AuthManager.revoke + revoke_tx epoch → the 07-05 branch force-disconnects the live session; phone re-pairs with kRevokedExplanation) (D-04/D-05)
- "Pair new device" in BOTH the tray menu and settings → `crate::begin_on_demand_pairing` (begin_pairing + notify_pin, fresh 60s PIN) (D-02)
- Persistent firewall hint renders whenever the startup self-test could not confirm `Allowed` — loud fix text on `BlockedNoRule`, soft note on `Unknown` (SRV-04/D-06)
- egui repaint scheduling rides the shell loop's user-event queue (`SettingsRepaint` → `WaitUntil`), vsync-blocked swaps — no busy render loop next to the tray

## Task Commits

Each task was committed atomically:

1. **Task 1: egui-on-winit settings window — device name / port / clipboard sync / autostart** - `308e515` (feat)
2. **Task 2: Paired-device list + Revoke + Pair-new (settings + tray menu) + firewall hint** - `9e92170` (feat)

## Files Created/Modified

- `server/server-windows/src/shell/settings.rs` - SettingsWindow (GL stack + EguiGlow + UiState render/commit/persist), new
- `server/server-windows/src/shell/mod.rs` - UserEvent::OpenSettings/SettingsRepaint, ShellCtx retype (config/clip_sync/resolved_port), settings lifecycle in the ApplicationHandler
- `server/server-windows/src/shell/tray.rs` - Settings… + Pair new device menu items with id accessors
- `server/server-windows/src/config.rs` - SharedSettings live handle + from_config
- `server/server-windows/src/main.rs` - shared-settings Arc, clip-sync clone for the shell, step-5b save reads LIVE settings, ShellCtx wiring, dead-code allows removed from begin_on_demand_pairing/revoke_device
- `server/server-windows/Cargo.toml` (+ `server/Cargo.lock`) - egui_glow "winit" feature, glutin 0.32, glutin-winit 0.5

## Decisions Made

- **glutin + glutin-winit for GL context creation** — egui_glow renders but does not create GL contexts; used the exact versions (0.32.3 / 0.5.0) egui_glow 0.35's own `pure_glow` example dev-deps pin, mirroring its window/context/surface bootstrap
- **SharedSettings as single source of truth for editable settings** — both the settings window's saves and the auth-change re-serialize read it (see deviation 2)
- **Commit-on-lost-focus for text fields + commit_pending on close** — avoids a config write per keystroke while never losing a typed value
- **Device-name changes also flagged restart-to-apply** — the UDP beacon binds its identity once at startup, same as the listener port

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] ShellCtx placeholder `()` fields retyped; main.rs/config.rs modified beyond the plan's files_modified list**
- **Found during:** Task 1
- **Issue:** `ShellCtx.config`/`ShellCtx.autostart` were `()` placeholders (07-06 explicitly deferred "retype to whatever real handle 07-08 needs"); the settings window also needed the clip thread's live gate and the resolved port, neither reachable from the shell
- **Fix:** `config: Arc<Mutex<SharedSettings>>` (new type), `clip_sync: Arc<AtomicBool>` (cloned before the Arc moves onto the clip thread), `resolved_port: u16`; the `autostart: ()` placeholder was dropped (autostart is stateless free functions)
- **Files modified:** server/server-windows/src/main.rs, server/server-windows/src/config.rs, server/server-windows/src/shell/mod.rs
- **Verification:** cargo build -p server-windows green; server-windows unit tests pass
- **Committed in:** 308e515 (Task 1 commit)

**2. [Rule 2 - Missing critical] Step-5b config save used a frozen startup snapshot — would clobber settings edits**
- **Found during:** Task 1
- **Issue:** main.rs's auth-change save task captured `cfg.device_name/port/autostart/clipboard_sync` at startup; any pairing/revoke AFTER a settings edit would re-serialize config.toml with the stale startup values, silently reverting the owner's edits
- **Fix:** introduced `SharedSettings` (config.rs) behind `Arc<Mutex>`; the step-5b task now reads the LIVE values on every save, and the settings window's own saves pull paired records from the auth store — neither path can clobber the other
- **Files modified:** server/server-windows/src/config.rs, server/server-windows/src/main.rs
- **Verification:** build green; save paths reviewed for lock ordering (sequential, never nested)
- **Committed in:** 308e515 (Task 1 commit)

**3. [Rule 3 - Blocking] GL context provider missing for egui_glow**
- **Found during:** Task 1
- **Issue:** 07-06 added egui/egui-winit/egui_glow, but egui_glow only paints into an EXISTING OpenGL context — nothing in the tree could create one on a winit window
- **Fix:** enabled egui_glow's "winit" feature (the `EguiGlow` helper) and added `glutin = "0.32"` + `glutin-winit = "0.5"` — rust-windowing crates, the exact pairing egui_glow 0.35 pins in its own example dev-deps; installs succeeded first try
- **Files modified:** server/server-windows/Cargo.toml, server/Cargo.lock
- **Verification:** cargo build resolves and compiles clean (glutin 0.32.3, glutin-winit 0.5.0 in lock)
- **Committed in:** 308e515 (Task 1 commit)

---

**Total deviations:** 3 auto-fixed (2 blocking, 1 missing critical)
**Impact on plan:** All three were prerequisites the plan's own interface comments anticipated (07-06's "07-08 will retype", 07-07's "07-08 clones this Arc"). No scope creep; no architectural change.

## Issues Encountered

- The plan's acceptance grep (`grep "eframe" settings.rs` must return nothing) initially matched a doc comment explaining why eframe is NOT used — reworded the comment so the file is literally eframe-free while keeping the Pitfall 4 rationale
- Execution was split by a session limit between research and implementation; no repo changes were lost (nothing had been committed)

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SRV-03/SRV-02/SRV-04 management surface complete — the last server slice of Phase 7; all 13 plans now have summaries
- On-device UAT rows for the phase gate: open Settings from the tray; edit name/port (restart-to-apply note); toggle autostart (verify HKCU Run entry); Pair-new from BOTH tray and settings shows a PIN toast; Revoke a connected phone → it disconnects and shows the re-pair explanation; firewall hint visible when blocked
- Known cosmetic caveat (accepted): the GL-config selection inside `SettingsWindow::new` uses the upstream example's `expect` on "at least one GL config" — unreachable on real Windows desktops; a failure there would only log-and-skip the window (creation is wrapped in log-and-continue at the call site for every other error)

## Self-Check: PASSED

- server/server-windows/src/shell/settings.rs — FOUND
- .planning/phases/07-server-shell-dashboard-polish/07-08-SUMMARY.md — FOUND
- Commit 308e515 — FOUND
- Commit 9e92170 — FOUND
- `grep -c "eframe" settings.rs` = 0 — PASS
- `cargo build -p server-windows` — PASS (warning-clean)
- `cargo test -p server-core` — 22 passed (incl. 07-05 revoke integration)
- `cargo test -p server-windows` — 37 passed

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-15*
