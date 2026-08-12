---
status: complete
quick_id: 260801-r8x
slug: stage-server-cargo-lock-in-the-release-c
type: quick
subsystem: infra
tags: [release, powershell, cargo, lockfile, git]

provides:
  - "`server/Cargo.lock` is staged into the release commit, so a release tag names a tree whose lockfile matches the built server binary"
  - "`cargo build --locked` is possible from a release tag"
  - "A completed release run leaves no dirty lockfile to trip the next run's clean-tree preflight"
affects: [12-03, 12-18, release, in-app-updates]

tech-stack:
  added: []
  patterns:
    - "Generated-but-tracked files that the release BUILD rewrites ride the release commit via `$BumpedFiles`, without passing through `Set-VersionField`"

key-files:
  created: []
  modified:
    - tools/release.ps1

key-decisions:
  - "The lockfile joins `$BumpedFiles` but never `Set-VersionField`: cargo stays its only writer, so the harness's three-`BUMP `-line contract is untouched"
  - "Placed second in the array, directly beneath `server/server-windows/Cargo.toml`, the file whose version it mirrors"

requirements-completed: [D-04, D-20]

duration: 6min
completed: 2026-08-01
---

# Quick 260801-r8x: Stage server/Cargo.lock in the release commit Summary

**`$BumpedFiles` in `tools/release.ps1` gains `server/Cargo.lock` as its second entry, so the lockfile cargo rewrites during the installer build is committed with the release instead of being left dirty and stale.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-08-01T11:05Z
- **Completed:** 2026-08-01T11:11Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- One array entry plus a six-line comment in `tools/release.ps1`; 7 insertions, **0 deletions**, one file.
- The fix reaches all three `$BumpedFiles` consumers from the single edit — the real `git add` (`:602`), the `DRYRUN` preview (`:585`), and the `git checkout --` revert hint in the pre-existing-tag error (`:598`).
- The verification harness is byte-identical and still green.

## Task Commits

1. **Task 1: stage server/Cargo.lock in the release commit** — `8b875b1` (fix)

## Files Created/Modified

- `tools/release.ps1` — `$BumpedFiles` now carries `'server/Cargo.lock'` in second position, directly beneath `'server/server-windows/Cargo.toml'`, with a comment in the file's existing voice (prose `#` lines, ASCII `--`, backticked paths) recording that cargo rewrites the lockfile's `server-windows` entry when the installer build below runs `cargo build`, that omitting it makes the tag name a tree whose lockfile pins the PREVIOUS version (`cargo build --locked` then fails from that tag), and that the leftover dirt trips the NEXT run's clean-tree preflight.

## Verification Evidence

**1. `DRYRUN git add` line observed AFTER the change** (captured from a real `tools/release.ps1 -Version 9.9.9 -DryRun` transcript), verbatim:

```
DRYRUN git add server/server-windows/Cargo.toml server/Cargo.lock app/remote_control/pubspec.yaml extension/manifest.json
```

Exactly one line matched that string anchored end-to-end. This is the proof the fix reached the consumer, not just the array literal. The RED baseline the planner captured on the clean tree lacked `server/Cargo.lock` entirely.

**2. Harness:** `tools/verify-release-dryrun.ps1` printed `OK` and exited **0**, unmodified (`git status` never listed it). The three-`BUMP `-line contract survived — the same transcript carries exactly 3 `BUMP ` lines, at the same three paths:

```
BUMP server/server-windows/Cargo.toml 1.4.0 -> 9.9.9
BUMP app/remote_control/pubspec.yaml 1.4.0+8 -> 9.9.9+9
BUMP extension/manifest.json 1.2.1 -> 9.9.9
```

**3. `server/Cargo.lock` never passes through `Set-VersionField`.** It is not version-*bearing* here: cargo remains its only writer, and the release commit merely carries it. That is exactly why the harness could not be affected — `BUMP ` lines are emitted only by `Set-VersionField`, so the count stays 3 and `$ExpectedPaths` stays at the same three paths. `tools/verify-release-dryrun.ps1` needed no edit.

**4. Scope:** `git diff --numstat -- tools server app extension installer protocol docs` listed exactly one row, `tools/release.ps1`, with 0 deletions. The commit deletes no files. `git ls-files --eol` reports `i/lf w/lf` for `tools/release.ps1` both before and after — LF preserved in index and worktree.

**5. Dry run still side-effect-free:** `git status --porcelain` after the dry run showed only the (then-uncommitted) `tools/release.ps1` edit and the untracked planning dir — no version file was written.

## Decisions Made

- **Comment placed inside the array literal, on its own lines above the entry.** PowerShell accepts `#` comment lines between array elements, and `tools/release.ps1` has no inline-trailing-comment precedent anywhere in the file, so the explanation sits next to the entry it explains rather than to the right of it.
- **Comment refers to the build *below*.** The `# ---- Build ----` section starts at `:508`, after the array at `:491`, so "the installer build below" is the accurate direction.

## Deviations from Plan

None — plan executed exactly as written. No auto-fix rules fired.

## Issues Encountered

- The plan's second verify command (`... -DryRun | Select-String -SimpleMatch ...`) reports **0** matches when the pipeline is built inside PowerShell, and this is a false negative, not a failure: `tools/release.ps1` writes its whole transcript with `Write-Host`, which goes to the host console and bypasses the success stream, so an in-process pipe receives no objects to match. Verified instead by redirecting the process's console output to a file and matching the line there, which yields the expected count of 1. Worth knowing for any future check that greps this script's output — pipe the *process*, not the PowerShell expression.

## Known Stubs

None.

## Next Phase Readiness

- `tools/release.ps1` is ready for the first real release run (12-03 onward). The outstanding blocker there is unchanged and unrelated: the public mirror repo `nandodeomkar/remote-control-releases` still does not exist, and the dry run continues to say so.
- No follow-up work is implied by this change.

## Self-Check: PASSED

- `tools/release.ps1` — FOUND; `git show HEAD:tools/release.ps1` carries `'server/Cargo.lock',` at line 499.
- `.planning/quick/260801-r8x-stage-server-cargo-lock-in-the-release-c/260801-r8x-SUMMARY.md` — FOUND.
- Commit `8b875b1` — FOUND in `git log --all`.

---
*Quick task: 260801-r8x*
*Completed: 2026-08-01*
