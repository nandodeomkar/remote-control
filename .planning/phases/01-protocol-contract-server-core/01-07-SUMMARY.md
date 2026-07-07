---
phase: 01-protocol-contract-server-core
plan: 07
subsystem: tooling
tags: [flutter, dart, sdk-install, environment, human-in-loop]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    plan: 06
    provides: "Rust half of the protocol contract complete (98 workspace tests green) — Dart half was the only remaining gap"
provides:
  - "Working Dart toolchain on this machine: Dart SDK 3.12.2 (stable) via Flutter 3.44.5 stable at C:\\dev\\flutter"
  - "Absolute dart path for Plan 08: C:\\dev\\flutter\\bin\\dart.bat (plain `dart` works in terminals opened after the setx)"
  - "Flutter available for Phase 2's app work — one install serves Phases 1-7"
affects: [01-08, phase-02]

# Tech tracking
tech-stack:
  added:
    - "Flutter SDK 3.44.5 stable (bundles Dart 3.12.2) — machine install, not a repo dependency"
  patterns: []

key-files:
  created: []
  modified: []

key-decisions:
  - "Flutter bundle route taken (not standalone Dart SDK) per RESEARCH recommendation — Phase 2 needs Flutter anyway"
  - "Install location C:\\dev\\flutter; user-scope setx PATH append only (system PATH untouched, T-01-33)"

patterns-established: []

requirements-completed: [CONN-07]

# Metrics
duration: 16min
completed: 2026-07-07
---

# Phase 01 Plan 07: Flutter SDK Install Summary

**Scripted install of Flutter 3.44.5 stable (Dart 3.12.2) from the official flutter_infra_release host, SHA-256 verified, user-PATH updated, confirmed by human checkpoint — Plan 08's `dart test` is unblocked**

## Performance

- **Duration:** ~16 min (dominated by the 1.9 GB download)
- **Completed:** 2026-07-07
- **Tasks:** 2 (1 auto + 1 blocking human-action checkpoint)
- **Files modified:** 0 (machine state only, per plan `files_modified: []`)

## Accomplishments

- Resolved the current stable release from the official manifest at `storage.googleapis.com/flutter_infra_release/releases/releases_windows.json` and downloaded `flutter_windows_3.44.5-stable.zip` (1,899,725,247 bytes) from the same official host — no mirrors, no third-party installers (T-01-32)
- SHA-256 verified against the manifest: `64ff1f561e0811bc724d597f9fe6faa6b3e74b11c02c320076fbbe239a717a11` (match); zip deleted from scratchpad after verification
- Extracted to `C:\dev\flutter`; user PATH appended with `C:\dev\flutter\bin` via user-scope `setx` (final PATH 1004 chars — under the 1024 setx truncation limit, verified intact in `HKCU\Environment`); system PATH untouched (T-01-33)
- Verified via absolute path: `dart.bat --version` → Dart SDK 3.12.2 stable (satisfies remote_protocol's `^3.5.0` constraint, A4); `flutter.bat --version` → Flutter 3.44.5 stable, DevTools 2.57.0

## Task Commits

No task commits — the plan declares `files_modified: []`; only this SUMMARY and tracking files are committed (docs commit).

## Checkpoint Resolution

Task 2 (`checkpoint:human-action`, blocking): user opened a fresh terminal and confirmed `dart --version` succeeds — approved 2026-07-07. The setx PATH change is live in new shells.

## Decisions Made

- Flutter bundle over standalone Dart SDK: RESEARCH recommendation held — one 1.9 GB install now covers Plan 08 (`dart test`) and every Flutter need in Phases 2-7

## Deviations from Plan

None — Task 1's scripted route succeeded end-to-end on the first attempt; the manual-fallback branch of Task 2 was never needed.

## Known Stubs

None.

## Issues Encountered

- Executor session hit the provider usage limit between checkpoint approval and closeout; the orchestrator completed the SUMMARY/state closeout inline. No install steps were affected.

## User Setup Required

None beyond the completed checkpoint — `dart` resolves in any terminal opened from now on; older shells need the absolute path `C:\dev\flutter\bin\dart.bat`.

## Next Phase Readiness

- Plan 01-08 can run `dart pub get` / `dart test` (use `C:\dev\flutter\bin\dart.bat` if PATH isn't loaded in the executor shell)
- Phase 2 (Flutter app) is unblocked: `flutter` 3.44.5 stable installed

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*

## Self-Check: PASSED

Machine-state truths verified: `C:/dev/flutter/bin/dart.bat --version` → Dart SDK 3.12.2 (≥3.5) confirmed by orchestrator post-checkpoint; official-host download recorded; no repo files changed.
