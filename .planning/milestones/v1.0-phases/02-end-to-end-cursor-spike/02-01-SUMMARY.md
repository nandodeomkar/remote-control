---
phase: 02-end-to-end-cursor-spike
plan: 01
subsystem: server
tags: [rust, enigo, windows, tokio, mpsc, dpi, sub-pixel, sendinput]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    provides: "server_core::run(listener, deps), ServerDeps, MouseKeys trait, AuthManager, binary move/scroll routing"
provides:
  - "server-windows crate: second workspace member, the composition root every later phase extends"
  - "EnigoMouseKeys: real MouseKeys executor forwarding move_rel/scroll to a dedicated input thread via std::sync::mpsc"
  - "SubPixelAccumulator: unit-tested fractional-remainder carry (PAD-05 crit 4) on the input thread"
  - "Dedicated OS input thread owning the !Sync Enigo handle (move_mouse Coordinate::Rel + scroll Axis injection)"
  - "DPI awareness at startup via enigo::set_dpi_awareness()"
  - "Stub Media/Power/Apps/Clipboard executors — Phase 4-6 seeds (D-08)"
  - "Runnable binary: prints pairing PIN, binds 0.0.0.0 (RC_PORT override, default 17777), runs server_core::run"
affects: [02-02, 02-03, 02-04, phase-4-keyboard, phase-5-control-center, phase-6-apps-clipboard, phase-7-tray]

# Tech tracking
tech-stack:
  added: [enigo 0.6.1, windows 0.62.2, tracing 0.1, tracing-subscriber 0.3, anyhow 1]
  patterns:
    - "Sync executor trait -> non-blocking mpsc send -> dedicated OS thread owning !Sync injection handle"
    - "Sub-pixel accumulation next to the injector (trunc + carry per axis), never in the trait method"
    - "Binary owns the tracing subscriber; server-core stays log-free"

key-files:
  created:
    - server/server-windows/Cargo.toml
    - server/server-windows/src/main.rs
    - server/server-windows/src/input_thread.rs
    - server/server-windows/src/executors/mod.rs
    - server/server-windows/src/executors/mouse_keys.rs
    - server/server-windows/src/executors/stubs.rs
  modified:
    - server/Cargo.toml

key-decisions:
  - "Default WebSocket port 17777 with RC_PORT env override (spec defines no numeric default; settings UI is Phase 7)"
  - "DEV_PIN shortcut NOT implemented: AuthManager has no fixed-PIN API and adding one would touch server-core; console-printed real PIN is sufficient for the owner's test loop (T-02-EP surface never created)"
  - "enigo::set_dpi_awareness() helper path used (confirmed re-exported at crate root in 0.6.1); windows-crate SetProcessDpiAwarenessContext fallback not needed"
  - "enigo 0.6.1 resolved by 'enigo = \"0.6\"' — no 0.7 drift, no =pin needed"
  - "Enigo injection failures on the hot path are dropped (send-and-forget), never panic the input thread"

patterns-established:
  - "Composition root pattern: DPI first, subscriber second, input thread third, ServerDeps, run — later phases extend main.rs, not core"
  - "Stub executors in server-windows/src/executors/stubs.rs are the growth point for Phases 4-6 (never reuse core test mocks at runtime)"

requirements-completed: [PAD-05]

# Metrics
duration: 45min
completed: 2026-07-08
---

# Phase 2 Plan 01: Server-Windows Cursor Vertical Summary

**server-windows crate with an enigo MouseKeys executor on a dedicated input thread: unit-tested sub-pixel accumulator, DPI-aware startup, and a runnable composition root that prints a PIN and runs server_core::run on the LAN**

## Performance

- **Duration:** 45 min
- **Started:** 2026-07-08T03:12:44Z
- **Completed:** 2026-07-08T03:58:04Z
- **Tasks:** 3 (Task 1 TDD: RED + GREEN commits)
- **Files modified:** 8 (7 source/manifest + Cargo.lock)

## Accomplishments

- `server-windows` is a second workspace member; `server-core` verified still free of enigo/`windows`-crate deps (`cargo tree -p server-core` clean — Phase 1 invariant intact)
- `SubPixelAccumulator` carries the fractional remainder per axis: 5 frames of 0.4px emit [0,0,1,0,1] (sum 2, cumulative trunc), integers pass through immediately, negatives flush symmetrically — all three Wave 0 behaviors unit-tested (PAD-05 crit 4 / D-04)
- The `!Sync` `Enigo` handle lives only on the dedicated input thread; `EnigoMouseKeys` holds just an `mpsc::Sender<Cmd>` and its `move_rel`/`scroll` are single non-blocking sends (hot-path contract honored)
- Boot smoke test: binary prints `Pairing PIN: <6 digits>`, logs `server-windows listening port=...`, binds without panic, keeps serving until killed
- Full workspace suite green: 101 tests (Phase 1 core + integration suites unaffected, 3 new accumulator tests)

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): failing sub-pixel accumulator tests + crate scaffold** - `157bb32` (test)
2. **Task 1 (GREEN): accumulator + enigo input thread implementation** - `cc67ab4` (feat)
3. **Task 2: EnigoMouseKeys executor + no-op stub executors** - `7596886` (feat)
4. **Task 3: composition root — DPI, subscriber, ServerDeps, run** - `016774b` (feat)

_Task 1 was TDD; no refactor commit was needed (GREEN implementation was already clean)._

## Files Created/Modified

- `server/Cargo.toml` - workspace members now `["server-core", "server-windows"]`
- `server/server-windows/Cargo.toml` - crate manifest: server-core path dep, enigo 0.6, windows 0.62 (Win32_Foundation + Win32_UI_HiDpi), tokio (core-matching features), tracing, tracing-subscriber (env-filter), anyhow
- `server/server-windows/src/input_thread.rs` - `Cmd` enum, `SubPixelAccumulator` (tested), `run_input_thread` owning `Enigo` with separate move/scroll accumulators
- `server/server-windows/src/executors/mouse_keys.rs` - `EnigoMouseKeys`: all 10 `MouseKeys` methods; move/scroll forward via mpsc, other 8 are Phase 4 stubs
- `server/server-windows/src/executors/stubs.rs` - `StubMedia`/`StubPower`/`StubApps`/`StubClipboard` runtime no-ops (`list -> vec![]`, `get -> String::new()`)
- `server/server-windows/src/executors/mod.rs` - module declarations
- `server/server-windows/src/main.rs` - composition root: `enigo::set_dpi_awareness()` first, EnvFilter subscriber, input thread spawn, `Executors` + `AuthManager` + pause watch, `TcpListener::bind(("0.0.0.0", port))`, `server_core::run`

## Decisions Made

- **Port default 17777, `RC_PORT` env override** — the design spec makes the port configurable but names no number; 17777 is unprivileged and uncommon. Settings UI arrives in Phase 7.
- **DEV_PIN not implemented** — the plan marked it optional; `AuthManager` generates its PIN via CSPRNG with no fixed-PIN API, so honoring DEV_PIN would require a server-core change (out of scope, and it removes the T-02-EP threat surface entirely). The console-printed real PIN serves the owner's test loop.
- **enigo helper path for DPI** — `enigo::set_dpi_awareness()` confirmed re-exported at the crate root in 0.6.1 source (`win/win_impl.rs:560`); the `windows`-crate fallback stays available via the already-declared `Win32_UI_HiDpi` feature but was not needed.
- **API drift check clean** — `cargo add --dry-run` resolved enigo 0.6.1 and windows 0.62.2; `move_mouse(i32, i32, Coordinate) -> InputResult<()>` and `scroll(i32, Axis) -> InputResult<()>` confirmed from source, matching RESEARCH Pattern 2 verbatim.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Declared `mod executors;` in main.rs during Task 2**
- **Found during:** Task 2 (EnigoMouseKeys executor + stubs)
- **Issue:** Task 2's file list omits main.rs, but new modules are dead files unless declared — `cargo build -p server-windows` (Task 2's verify) would never compile them
- **Fix:** Added the one-line `mod executors;` declaration (main.rs is in the plan's overall `files_modified` list; the full composition root landed in Task 3 as planned)
- **Files modified:** server/server-windows/src/main.rs
- **Verification:** `cargo build -p server-windows` compiles the executor modules
- **Committed in:** `7596886` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Trivial wiring necessary for the task's own verify step. No scope creep.

## Known Stubs

All stubs below are **intentional per the plan** (D-08 seeds; the spike only needs the mouse path) and are tracked for later phases:

| Stub | File | Resolved by |
|------|------|-------------|
| `click`/`button_down`/`button_up`/`key_down`/`key_up`/`key_tap`/`type_text`/`backspace` no-ops on `EnigoMouseKeys` | server/server-windows/src/executors/mouse_keys.rs | Phase 4 (each carries a `// Phase 4: fills this` marker) |
| `StubMedia`, `StubPower` no-ops | server/server-windows/src/executors/stubs.rs | Phase 5 |
| `StubApps` (`list -> vec![]`), `StubClipboard` (`get -> ""`) | server/server-windows/src/executors/stubs.rs | Phase 6 |

None block this plan's goal (cursor move/scroll path is fully real).

## TDD Gate Compliance

- RED gate: `157bb32` (`test(02-01)`) — all 3 accumulator tests failed on `todo!()` before implementation
- GREEN gate: `cc67ab4` (`feat(02-01)`) — all 3 tests pass
- REFACTOR: not needed (no cleanup required after GREEN)

## Issues Encountered

None — enigo 0.6.1's API matched RESEARCH assumptions exactly (no rand/hmac-style rename surprises this time).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 02-02 (Flutter app scaffold + TCP_NODELAY connector) can proceed independently (wave 1 sibling); Plans 03/04 get a runnable server to connect to: `cargo run -p server-windows` prints the PIN and listens on 0.0.0.0:17777 (`RC_PORT` to override)
- The manual cursor-moves/latency verification is deferred to the Plan 04 human gate as planned; scroll wheel-direction sign convention (RESEARCH A4) also verifies there
- Composition root is the permanent extension point: Phase 4-7 fill the executor stubs and replace the console PIN with the tray

## Self-Check: PASSED

- All 7 created/modified source files exist on disk
- Commits `157bb32`, `cc67ab4`, `7596886`, `016774b` present in git log
- `cargo test --workspace`: 101 passed, 0 failed
- `cargo tree -p server-core`: no enigo/windows deps (invariant preserved)

---
*Phase: 02-end-to-end-cursor-spike*
*Completed: 2026-07-08*
