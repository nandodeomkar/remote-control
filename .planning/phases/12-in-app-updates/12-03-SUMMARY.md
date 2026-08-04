---
phase: 12-in-app-updates
plan: 03
subsystem: distribution
tags: [release, github-releases, mirror, versioning, sha256, d-01, d-04, d-21]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 01
    provides: "tools/release.ps1 and tools/verify-release-dryrun.ps1 -- the script this plan ran for real for the first time, and the asset-name contract it publishes under"
  - phase: 12-in-app-updates
    plan: 06
    provides: "the ureq edit to server/server-windows/Cargo.toml that had to land before this plan rewrote that same file's version line"
provides:
  - "nandodeomkar/remote-control-releases -- the public mirror, now non-empty, with main seeded and one published release"
  - "v1.5.0 -- the first real release: three digest-bearing assets readable anonymously, satisfying D-21 for every client-side plan"
  - "The three version files unified at 1.5.0 (1.5.0+9 for the app), committed by the script as b6d405d"
  - "DISTRIBUTION.md rewritten around tools/release.ps1, the two repositories, and both caveats"
affects: [12-10, 12-12, 12-13, 12-15, 12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "The release is produced by one command; the operator's only manual act is running it. No artifact is built, bumped, tagged or published by hand."

key-files:
  created:
    - .planning/phases/12-in-app-updates/12-03-SUMMARY.md
  modified:
    - DISTRIBUTION.md
    - server/server-windows/Cargo.toml
    - server/Cargo.lock
    - app/remote_control/pubspec.yaml
    - extension/manifest.json

key-decisions:
  - "v1.5.0 was published from 2cd05f5 (the DISTRIBUTION.md commit) rather than the end-of-wave-2 tree the objective assumed, because sibling plan 12-09 landed first in the same wave. Orchestrator-approved; the extra modules are inert."
  - "After the publish stage failed, tools/release.ps1 was NOT re-run. Its tag preflight would have refused, and re-running would have rebuilt three artifacts to no purpose -- the recovery ran the script's own printed gh line instead, which is exactly what that error message exists for."
  - "The mirror's main branch was seeded with a README rather than by pushing anything from the private repo, keeping the mirror free of source and history (D-01)."
  - "DISTRIBUTION.md states that the in-app Updates screen ships in 1.6.0, rather than describing it as already available -- 1.5.0 predates it by construction."

requirements-completed: [D-01, D-02, D-04, D-20, D-21, SC1]

# Metrics
duration: ~45min (incl. one blocking permission checkpoint)
completed: 2026-08-04
---

# Phase 12 Plan 03: First Real Release Summary

**The public mirror now answers an anonymous client: `v1.5.0`, three assets under
the locked names, every one of them `uploaded` and carrying a `sha256:` digest
that matches what the build machine printed — produced by `tools/release.ps1`,
not by hand, with all three components agreeing on one version for the first
time in the project's history.**

## Provenance

| Fact | Value |
|---|---|
| Built from | `2cd05f52b4a7788515ab1f227a95c7c4eef06881` |
| Bump commit (by the script) | `b6d405d chore(release): v1.5.0` |
| Private tag | `v1.5.0`, pushed to `origin` |
| Mirror release | https://github.com/nandodeomkar/remote-control-releases/releases/tag/v1.5.0 |
| Mirror initial commit | `53f310a0f4bded51400a32d95eb13112638308db` (`README.md` on `main`) |

Published sha256 values, each verified equal to the `SHA256 ...` line the script
printed on this machine:

```
RemoteControl-v1.5.0.apk            083e3d13293387c51ba8839b13b546c5e5a0275adb0b8b0e038187ee8ef200b1
RemoteControl-Setup-v1.5.0.exe      d611dd33e5eadede0a22382ce00f57088ccf98d51790794633a9b12788e00067
RemoteControl-Extension-v1.5.0.zip  5bcdba6344f2a6371020343547043824c4dce2bedba737b230996a9a21b30df8
```

## What Was Done

### Task 1 — the public mirror repo (satisfied by the owner, no code commit)

The repo already existed when this plan was dispatched; it was **verified, not
re-attempted**, per the orchestrator's instruction:

- anonymous `GET /repos/nandodeomkar/remote-control-releases` → `200`
- same response → `private=False`, `visibility=public`
- `gh auth status` → exit 0, account `nandodeomkar`, scopes `gist, read:org, repo, workflow`

`gh` is not on PATH; it resolves at `C:\Program Files\GitHub CLI\gh.exe`, which
`release.ps1` already handles as a fallback candidate rather than a hardcoded
sole path.

### Task 2 — the first real publish

**Dry run first.** `tools/verify-release-dryrun.ps1` printed `OK` and exited 0.
`tools/release.ps1 -Version 1.5.0 -DryRun` exited 0 with **no refusals at all** —
preflight 5 reported `the mirror has no releases yet -- 1.5.0 is the first`,
which is the two-probe path 12-01 added specifically so the first-ever release
could be published. The previewed bumps were exactly the three expected:

```
BUMP server/server-windows/Cargo.toml 1.4.0 -> 1.5.0
BUMP app/remote_control/pubspec.yaml  1.4.0+8 -> 1.5.0+9
BUMP extension/manifest.json          1.2.1 -> 1.5.0
```

Nothing in the dry run warranted a different version or a `-PreRelease`
rehearsal, so no deviation from `-Version 1.5.0` was proposed.

**Live run.** Preflight, bump, three builds, the sha256 print, the private-repo
commit and the tag push all succeeded. The publish stage failed — see Deviation
1 — and was completed by the recovery described there. The final state is the
one the plan asked for.

**Anonymous verification** (re-run independently at close-out, no auth header):
`tag_name` `v1.5.0`, `draft` False, `prerelease` False, exactly 3 assets, all
three names exact, every `state` `uploaded`, every `digest` matching
`^sha256:[0-9a-f]{64}$` and equal to the printed value. No asset had a null
digest, so the D-15 hard stop was not reached.

The version files were committed by the script itself in `b6d405d` and were
**not re-committed** here; `git status --porcelain` is empty for all three.

### Task 3 — DISTRIBUTION.md (`2cd05f5`)

Rewritten so the release procedure is `tools/release.ps1` and nothing else. Six
sections: **Releasing** (the six stages as a table, the five refusals with what
to do about each, and `-DryRun` stated as side-effect-free with
`verify-release-dryrun.ps1` named as the proof), **Two repositories** (D-01's
reason in one sentence — an embedded token is extractable from an APK and a PAT
expires, breaking every installed client on rotation), **One version across
three components** (the three files and their anchors, and why the `+N` build
number must strictly increase), **Pre-releases** (`-PreRelease` is never offered
to clients, twice over: `releases/latest` excludes it and the client parser
rejects the suffix; other channels are out of scope), **Installing an update**
(in-app is the normal route, manual remains for first installs and recovery),
and **Known one-time cost**.

The by-hand build commands are gone; the one-time prerequisites (Inno Setup, the
`gh` login, the keystore and `key.properties`) are kept, since the script refuses
without them.

## Deviations from Plan

### 1. [Accepted, orchestrator-approved] v1.5.0 was not built from the end-of-wave-2 tree

- **Where:** the plan's `<objective>`.
- **Issue:** the objective states v1.5.0 is built from the end of wave 2 and
  therefore carries the 1.8 codecs, the `UpdateExecutor` trait, the feed/download
  modules and the Android install channel, but not the router arms, the update
  thread or the Updates screen. Sibling plan **12-09** completed first in this
  same wave, so HEAD had already advanced to `83b3893`.
- **Effect:** v1.5.0 additionally contains
  `server/server-windows/src/update/marker.rs` and
  `server/server-windows/src/update/apply.rs`. Both compile into the shipped
  binary but are wired to nothing — no router arm and no update thread calls
  them — so they are **inert** in v1.5.0. The plan's actual purpose (D-21: a
  real, anonymously readable release for later plans to check against) is
  unaffected, and v1.5.0 still cannot be tapped to install, exactly as the plan
  says.
- **Not rewound.** Building from an older commit was explicitly ruled out; the
  exact build sha is recorded above instead, which is what step 0 asked for.

### 2. [Rule 3 — Blocking] The mirror repo was bare, so `gh release create` returned 422 "Repository is empty"

- **Found during:** Task 2, at the publish stage — after the bump, all three
  builds, the commit and both pushes had already succeeded.
- **Issue:** the repo declared `default_branch: main` but had **zero branches**
  and `size: 0`. A GitHub release must attach to a ref, so the API refused:

  ```
  HTTP 422: Validation Failed (.../releases/364843547)
  Repository is empty.
  ```

  This was neither an auth failure nor a pre-existing draft — the two causes the
  script's own error text guesses at. Task 1's spec said "an empty repo with a
  README is the correct starting state"; the repo was created with neither a
  README nor any other commit, and nothing in the flow noticed until the very
  last step.
- **Partial state at that moment, all verified:** bump committed as `b6d405d`
  and pushed; tag `v1.5.0` created and pushed; three artifacts present in
  `dist/`; working tree clean; **mirror completely untouched** — zero releases,
  zero drafts, and `releases/364843547` itself returned 404, so the 422 left no
  half-created release behind.
- **Fix (both steps user-approved):** (1) seeded the mirror's `main` with a
  `README.md` via `gh api ... contents/README.md -X PUT`, commit `53f310a`. It
  states that the repo holds only binaries and release notes, lists the three
  asset names, notes each asset carries a SHA-256 digest, and notes pre-releases
  are never offered to clients. **No token appears in it** (D-01/T-12-02).
  (2) ran the exact `gh release create` line the script had printed in its
  failure message. Exit 0.
- **`release.ps1` was deliberately NOT re-run** — the tag was already pushed, so
  its tag preflight would have refused, and a re-run would have rebuilt three
  artifacts for nothing. Running the printed command is precisely the recovery
  that error message exists to enable, and it worked as designed.

### 3. [Process] The live publish required a human permission grant

- **Found during:** Task 2, step 3.
- **Issue:** the executor's two attempts to run
  `powershell.exe -File tools\release.ps1 -Version 1.5.0` were denied by the
  permission classifier. The dry run had already completed cleanly.
- **Handling:** returned a `checkpoint:human-action` with the full partial state,
  the verified preconditions, and the exact command needing permission. The
  script was **not** decomposed into its individual `git tag` / `gh release
  create` steps, since that would have bypassed the intent of the denial rather
  than satisfied it. The user granted permission in chat and the orchestrator ran
  the publish.

### Interpretation choice (not a deviation)

- **`DISTRIBUTION.md` labels the in-app Updates screen as shipping in 1.6.0.**
  Task 3 asks the doc to say the in-app path "is now the normal route". Written
  flatly that would be false on the day it was committed — 1.5.0 predates the
  Updates screen by construction. The section describes the in-app path as the
  normal route and carries a one-line status note naming 1.6.0 as the release it
  arrives in. Both statements the acceptance criteria require are present
  verbatim.

## Verification

| Check | Result |
|---|---|
| `powershell -File tools/verify-release-dryrun.ps1` | `OK`, exit 0 |
| `tools/release.ps1 -Version 1.5.0 -DryRun` | exit 0, zero refusals, 3 BUMP lines |
| anonymous `GET /repos/<mirror>` | 200, `private=False`, `visibility=public` |
| `gh auth status` | exit 0, `nandodeomkar` |
| anonymous `releases/latest` `tag_name` | `v1.5.0`, `draft=False`, `prerelease=False` |
| asset count / names | 3, exactly the three locked names |
| every asset `state` | `uploaded` |
| every asset `digest` | matches `^sha256:[0-9a-f]{64}$` and equals the printed sha256 |
| `grep '^version' server/server-windows/Cargo.toml` | `1.5.0` |
| `grep '^version:' app/remote_control/pubspec.yaml` | `1.5.0+9` (build number increased from 8) |
| `grep '"version"' extension/manifest.json` | `1.5.0` (from 1.2.1) |
| `git tag --list v1.5.0` | non-empty |
| `git status --porcelain` | empty |
| `python -c ... DISTRIBUTION.md` (plan's automated check) | `OK` |
| `grep -c 'release.ps1' DISTRIBUTION.md` | 6 (≥3 required) |
| pre-release sentence / first-upgrade sentence in DISTRIBUTION.md | present (lines 141, 224) |

## Success Criteria Status

- **SC1** — demonstrated end to end, for real, once: three artifacts published
  under one tag, all agreeing on `1.5.0`, produced by the script.
- **D-21** — satisfied. A real release now exists for every client-side leg of
  the phase to check against.
- **No token in any repo, artifact or workflow** — the mirror README was written
  by hand and contains none; the script authenticates only through the
  operator's own `gh` login; the three assets are build outputs.

## Threat Flags

None. The plan's three `mitigate` dispositions are discharged: **T-12-01** (the
asset names are the locked contract the server resolves from a compiled-in
prefix, and every digest is predictable and verifiable), **T-12-02** (the mirror
holds one README and three binaries — no source, no `.planning/`, no token),
**T-12-07** (every published asset was checked anonymously to carry a `sha256:`
digest equal to the locally computed value; a null digest would have been a hard
stop). **T-12-09** remains `accept` as planned.

## Known Stubs

None. `1.5.0` deliberately cannot be tapped to install — the Updates screen does
not exist yet — but that is the plan's stated purpose for this release, not a
stub. `12-18` publishes `1.6.0` and `1.6.1` from the finished tree.

## For Future Phases

- **12-18 publishes into this same mirror, and the empty-repo failure mode is now
  permanently gone** — `main` exists with one commit. But **`tools/release.ps1`
  has no preflight for an empty mirror**: its repo probe only checks that
  `/repos/<mirror>` returns 200, which a bare repo does. Any future fresh mirror
  would hit the identical 422 after a full build. **Worth a follow-up:** a sixth
  preflight reading `size`/`default_branch` (or `GET /repos/<mirror>/commits`
  returning 409) would catch it in the first second instead of after three
  builds. Not fixed here — this plan owns four files and the script is not one
  of them.
- **`release.ps1` is not idempotent after a publish-stage failure.** Once the tag
  is pushed, a re-run refuses at the tag check. The script says so in its own
  error text and hands back the exact `gh release create` line to finish by
  hand — use that, do not delete the tag and re-run. Whoever debugs the next
  failed publish should read the failure message before reaching for a rebuild.
- **The mirror's rate limit is 60 anonymous requests/hour per IP**, shared by the
  phone and the PC behind one NAT. Verification loops that poll
  `releases/latest` should not run in tight iterations.
- **`v1.5.0` is the floor for every later comparison.** `12-18`'s `1.6.0` and
  `1.6.1` must both be strictly greater or the script refuses them as an
  argument error — which throws even under `-DryRun`.

## Self-Check: PASSED

- `DISTRIBUTION.md` — FOUND
- `.planning/phases/12-in-app-updates/12-03-SUMMARY.md` — FOUND
- `server/server-windows/Cargo.toml` at 1.5.0 — FOUND
- `app/remote_control/pubspec.yaml` at 1.5.0+9 — FOUND
- `extension/manifest.json` at 1.5.0 — FOUND
- commit `2cd05f5` — FOUND
- commit `b6d405d` — FOUND
- tag `v1.5.0` — FOUND
- mirror release `v1.5.0` with 3 digest-bearing assets — FOUND (anonymous)
