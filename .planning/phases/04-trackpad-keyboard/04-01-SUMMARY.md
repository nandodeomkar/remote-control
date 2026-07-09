---
phase: 04-trackpad-keyboard
plan: 01
subsystem: server-input
tags: [rust, windows, sendinput, enigo, win32, virtual-desktop, pointer]

# Dependency graph
requires:
  - phase: 02-cursor-pipeline
    provides: input thread (Cmd channel, SubPixelAccumulator, non-fatal-injection rule) and the 0x01 move hot path
provides:
  - normalize_virtual pure fn (virtual-desktop pixel -> 0..65535 absolute grid, clamped, display-free unit tests)
  - VirtualMetrics plain-i32 struct (no windows types)
  - inject_absolute + cursor_pos private Win32 helpers (unsafe isolated)
  - Cmd::Move arm injects ABSOLUTE via SendInput with MOUSEEVENTF_VIRTUALDESK (ballistics bypass, multi-monitor correct)
  - Win32_UI_Input_KeyboardAndMouse + Win32_UI_WindowsAndMessaging feature flags on windows 0.62
affects: [04-trackpad-keyboard later plans, phase-5 executors, end-of-phase on-device gate]

# Tech tracking
tech-stack:
  added: []
  patterns: [absolute-inject-from-fresh-GetCursorPos, pure-fn-normalization-testable-without-display, unsafe-win32-isolated-in-private-helpers]

key-files:
  created: []
  modified:
    - server/server-windows/src/input_thread.rs
    - server/server-windows/Cargo.toml
    - server/server-core/src/auth/mod.rs

key-decisions:
  - "normalize_virtual clamps targets to the virtual desktop BEFORE normalizing, so any input (incl. cursor-at-edge + delta) stays in 0..=65535 — implements T-04-01 mitigation stronger than the in-bounds-only test spec"
  - "cx.saturating_add(ix) guards target arithmetic so debug-build overflow can never panic the input thread (T-04-01 never-panic rule)"
  - "Cargo.toml feature flags committed with the GREEN implementation commit (features are impl enablers, not test scaffold)"

patterns-established:
  - "Absolute injection reads GetCursorPos fresh each frame + accumulator integer delta — the OS carries position, the accumulator carries only the fraction (Pitfall 3)"
  - "unsafe Win32 lives only in private helpers (cursor_pos, inject_absolute); match arms stay safe code"

requirements-completed: [PAD-01]

# Metrics
duration: 10min
completed: 2026-07-09
---

# Phase 4 Plan 01: Absolute Pointer Injection Summary

**Cursor moves now inject ABSOLUTE via raw SendInput with MOUSEEVENTF_VIRTUALDESK — slow drags bypass the Windows "Enhance pointer precision" ballistics curve (D-01), the sub-pixel accumulator is untouched (D-02), and normalization spans the whole multi-monitor virtual desktop via a display-free unit-tested normalize_virtual (D-03).**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-09T18:49:11Z
- **Completed:** 2026-07-09T18:59:00Z
- **Tasks:** 2 (Task 1 TDD: RED + GREEN commits)
- **Files modified:** 3

## Accomplishments

- `normalize_virtual(target_x, target_y, VirtualMetrics) -> (i32, i32)`: MS round-to-nearest convention `((p - origin) * 65535 + (span-1)/2) / (span-1)`, i64 intermediate math, input clamped to the virtual desktop — proven by 3 unit tests that run on any host with no display (primary-origin corners/center, negative-origin secondary, never-leaves-grid sweep + i32::MIN/MAX clamp)
- `Cmd::Move` arm replaced: `move_acc.step()` first (D-02 verbatim), then `GetCursorPos` fresh each frame + integer delta -> `inject_absolute` -> one `INPUT_MOUSE` with `MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`; scroll arm stays on enigo
- Injection failures stay non-fatal: failed `GetCursorPos` or `SendInput` drops the frame (`let _ =` / `Option` early-out), never panics; `saturating_add` on target arithmetic
- Enabled `Win32_UI_Input_KeyboardAndMouse` + `Win32_UI_WindowsAndMessaging` features on the already-locked windows 0.62 dep — zero new packages (T-04-SC accepted disposition upheld)

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): failing tests for normalize_virtual** - `cb673bb` (test)
2. **Task 1 (GREEN): normalize_virtual + Win32 feature flags** - `b1816f9` (feat)
3. **Deviation fix: AuthManager Default impl** - `20e46f6` (refactor)
4. **Task 2: absolute-inject Cmd::Move arm** - `14f5a47` (feat)

_Task 1 was TDD: RED commit (tests failed on missing symbols — the right reason), GREEN commit (all 3 pass), no refactor needed._

## Files Created/Modified

- `server/server-windows/src/input_thread.rs` - VirtualMetrics + normalize_virtual (pure, pub), cursor_pos + inject_absolute (private, unsafe isolated), absolute Cmd::Move arm, 3 new unit tests, module docs updated; `Coordinate` import dropped (only the move arm used it)
- `server/server-windows/Cargo.toml` - windows 0.62 features: added Win32_UI_Input_KeyboardAndMouse, Win32_UI_WindowsAndMessaging (kept Win32_Foundation, Win32_UI_HiDpi)
- `server/server-core/src/auth/mod.rs` - Default impl for AuthManager (clippy gate unblock, no behavior change)

## Decisions Made

- **Clamp inside normalize_virtual:** the plan's Test C only required in-bounds targets to stay in 0..=65535, but the threat register (T-04-01) says injection "can never target outside the virtual desktop" — since target = GetCursorPos + delta can legitimately exceed the desktop at screen edges, clamping in the pure fn is the correct mitigation. Tested with i32::MIN/i32::MAX inputs.
- **Degenerate-metrics guard:** `(span - 1).max(1)` prevents divide-by-zero if GetSystemMetrics ever reports a 0/1-px axis — returns grid origin instead of panicking (never-panic rule).
- **Feature flags in the GREEN commit** rather than RED: the pure tests don't need Win32; features are implementation enablers for Task 2's helpers.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Installed rustup clippy component**
- **Found during:** Task 2 (verify step)
- **Issue:** `cargo clippy` not installed for toolchain 1.89-x86_64-pc-windows-msvc; the plan's verify command could not run
- **Fix:** `rustup component add clippy` — official first-party toolchain component (NOT a third-party package; package-legitimacy checkpoint not applicable)
- **Files modified:** none
- **Verification:** clippy runs and passes
- **Committed in:** n/a (toolchain, no repo change)

**2. [Rule 3 - Blocking] AuthManager missing Default impl failed clippy -D warnings**
- **Found during:** Task 2 (verify step)
- **Issue:** Pre-existing `new_without_default` lint in `server-core/src/auth/mod.rs`, surfaced only now that clippy exists on this machine; `cargo clippy -p server-windows -- -D warnings` also checks the path dependency, so the plan's verify gate was hard-blocked
- **Fix:** Added `impl Default for AuthManager` delegating to `new()` — six lines, no behavior change
- **Files modified:** server/server-core/src/auth/mod.rs
- **Verification:** `cargo clippy -p server-windows -- -D warnings` clean; `cargo test -p server-core` all green
- **Committed in:** `20e46f6` (separate refactor commit)

---

**Total deviations:** 2 auto-fixed (both Rule 3 blocking)
**Impact on plan:** Both were required to run the plan's own verify gate. No scope creep; no behavior changes outside the plan's files.

## Issues Encountered

- Transient dead-code warnings between the GREEN commit and Task 2 (normalize_virtual unused until the move arm wired it) — expected and resolved within the plan; final clippy `-D warnings` is clean.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The OS-injection foundation for the phase is live: both later client slices (trackpad, keyboard) can now be verified on-device against real 1:1 injection.
- **Deferred to the end-of-phase on-device gate** (human_verify_mode = end-of-phase, 04-VALIDATION Manual-Only): slow-drag 1:1 with "Enhance pointer precision" ON; dual-monitor seam crossing with no jump/clamp.
- Verification status: `cargo test -p server-windows` 6/6 green (3 kept SubPixelAccumulator + 3 new normalize_virtual); `cargo clippy -p server-windows -- -D warnings` clean; `cargo build -p server-windows` compiles with the new features.

## Self-Check: PASSED

- All 4 claimed files exist on disk
- All 4 task commits present in git log (cb673bb, b1816f9, 20e46f6, 14f5a47)
- Must-have artifacts verified: `fn normalize_virtual` in input_thread.rs, `Win32_UI_Input_KeyboardAndMouse` in Cargo.toml

---
*Phase: 04-trackpad-keyboard*
*Completed: 2026-07-09*
