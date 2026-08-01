---
phase: quick-260801-rgl
plan: 01
subsystem: infra
tags: [github-actions, ci, cargo, workspace, cross-platform]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: "server-core / server-windows cargo workspace split, with server-core holding the zero-Windows-deps invariant"
provides:
  - "CI `rust` job scoped to `cargo test -p server-core`, so an ubuntu runner no longer builds the Windows-only `server-windows` crate"
  - "An in-file comment recording WHY `--workspace` must not be restored"
affects: [ci, release, phase-12-in-app-updates]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CI asserts a crate-scoped invariant with `-p <crate>`, not `--workspace`, when workspace members are platform-specific"

key-files:
  created: []
  modified: [.github/workflows/ci.yml]

key-decisions:
  - "Scope the Linux CI job to `-p server-core` rather than installing GTK dev headers on the runner — building a Windows-only binary on ubuntu proves nothing and would still fail to link the `windows` crate"
  - "Keep `Swatinem/rust-cache`'s `workspaces: server` — it is a cache path, not a cargo `--workspace` flag, and is unrelated to the defect"
  - "Record the rationale as a two-line comment above the run step so a future reader does not 'helpfully' restore `--workspace`"

patterns-established:
  - "Platform-specific workspace members are excluded from cross-platform CI by package selector, not by installing their system dependencies"

requirements-completed: [QUICK-260801-RGL]

# Metrics
duration: ~8min
completed: 2026-08-01
---

# Quick Task 260801-rgl: Scope the Rust CI job to server-core Summary

**The CI `rust` job now runs `cargo test -p server-core` instead of `cargo test --workspace`, so the ubuntu runner stops pulling `server-windows`'s GUI stack (tray-icon/winit/egui/glutin → `glib-sys` → missing GTK headers) into the build.**

## Performance

- **Duration:** ~8 min
- **Completed:** 2026-08-01T14:22:04Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- `jobs.rust`'s last step is now `- run: cargo test -p server-core`. `--workspace` survives in the file only inside the new explanatory comment, by design.
- The `runs-on:` inline comment now names the crate that actually owns the claim: `# proves server-core's zero-Windows-deps claim by construction`. The `#` stayed in its original column.
- A two-line full-line comment above the run step records why the workspace is not tested on Linux, so the flag is not restored later.
- `jobs.dart` is byte-identical; the file is still LF-only with its trailing newline, and the terse compact-flow-mapping style is preserved.

## Task Commits

1. **Task 1: Scope the CI rust job to server-core and record why** - `8064301` (fix)

Docs artifacts (this SUMMARY, STATE.md) are intentionally left uncommitted — the orchestrator owns that commit.

## Files Created/Modified

- `.github/workflows/ci.yml` — `jobs.rust` only: run step scoped to `-p server-core`, `runs-on` comment tightened, rationale comment added. 4 insertions, 2 deletions.

## Verification Results

All five planned gates ran from the repo root. All passed.

| Gate | What it proves | Result |
|------|----------------|--------|
| G1 | `cargo test -p server-core` on this Windows machine | **exit 0** — 164 tests across 5 binaries (110 + 16 + 4 + 9 + 25) plus doc-tests, 0 failed. Matches the orchestrator's pre-change baseline exactly. |
| G2 | Workflow parses as YAML; `jobs.rust` has exactly one run step `cargo test -p server-core`; `jobs.dart` run steps still `['dart pub get','dart analyze --fatal-infos','dart test']` | `ci.yml OK` — comment-immune (PyYAML strips `#`), so it cannot be satisfied by comment text alone |
| G3 | No `\r` anywhere; file ends with `\n` | `LF OK`. Re-checked on the **committed blob** after commit (`git cat-file -p HEAD:...`): CRLF present `False`, ends with newline `True` |
| G4 | `server-core/Cargo.toml` with comments stripped declares no windows/GUI crate | `PASS: no windows/GUI deps in server-core` |
| G5 | Blast radius | `git diff --name-only` listed exactly `.github/workflows/ci.yml` |

Post-commit deletion check: `git diff --diff-filter=D HEAD~1 HEAD` returned nothing.

**Note on a benign git warning.** Both the `git add` and `git commit` printed `warning: in the working copy of '.github/workflows/ci.yml', LF will be replaced by CRLF the next time Git touches it` — this is the repo's `core.autocrlf` checkout behaviour, not something this change introduced. The committed blob was verified LF-only after the fact (see G3), which is what GitHub Actions reads.

## Honest limit of this verification — READ BEFORE TRUSTING THE FIX

**The Linux failure is NOT confirmed fixed by anything done here.** G1 ran on Windows, against a different target triple and a different set of pre-built artifacts than the ubuntu runner uses. A green local `cargo test -p server-core` cannot and does not demonstrate the ubuntu-latest outcome.

What the local evidence actually supports:

- **G4 is the strongest available argument, and it is a static one.** `server-core/Cargo.toml` declares only tokio, tokio-tungstenite, futures-util, serde, serde_json, sha2, hmac, rand, subtle, thiserror, hex, and if-addrs (plus a dev-only tokio `test-util` feature). Every one is cross-platform, so nothing in that dependency graph can reach `glib-sys`. That is a manifest-level inference, not an observed Linux build.
- **G2 proves the runner will now be asked to build only `server-core`.** It does not prove that build succeeds there.

**The actual proof is the `rust` job going green on the CI run after this branch is pushed.** That run is outside this task's scope and has not happened. Until it does, the correct status of the 31-of-31-red `rust` job is "expected to be fixed, unconfirmed."

## Decisions Made

None beyond what the plan specified — the three plan-level decisions (scope over GTK headers, keep `workspaces: server`, add the rationale comment) were followed as written.

## Deviations from Plan

None — plan executed exactly as written. The resulting `jobs.rust` block matches the plan's target block character-for-character.

## Issues Encountered

None. The only surprise was cosmetic: git's autocrlf warning on stage/commit, which was resolved by verifying the committed blob's bytes directly rather than trusting the working-copy check alone.

## Known Stubs

None.

## Threat Flags

None. No package was added, removed, or version-changed; `server/Cargo.toml`, both member manifests, and `Cargo.lock` are untouched, so T-RGL-SC's "accept" disposition still holds. T-RGL-01's mitigation was discharged by G2 (pins the exact run command AND the untouched `dart` step list) and G4 (proves the narrowed scope still asserts a real invariant rather than being a vacuous green).

## User Setup Required

None.

## Next Phase Readiness

- Ready. The change is committed on `gsd/phase-12-wave-1`; no branch or worktree was created or switched.
- **Outstanding, and the only thing that closes this task honestly:** watch the `rust` job on the first CI run after this branch is pushed. If it is green, the 2026-07-16 regression is closed. If it is still red, the failure mode has changed and the new log needs reading — do not assume it is the same `glib-2.0` error.

---
*Quick task: 260801-rgl*
*Completed: 2026-08-01*

## Self-Check: PASSED

- `.github/workflows/ci.yml` — FOUND (modified, committed)
- Commit `8064301` — FOUND in `git log`
- SUMMARY path `.planning/quick/260801-rgl-scope-the-rust-ci-job-to-server-core/260801-rgl-SUMMARY.md` — written
