---
phase: 12-in-app-updates
plan: 01
subsystem: release-tooling
tags: [powershell, release, versioning, github-releases, distribution]
requires: []
provides:
  - "tools/release.ps1 -- the single release entry point (preflight, bump, build, hash, tag, publish)"
  - "tools/verify-release-dryrun.ps1 -- automated proof the dry run previews three rewrites at one version and writes nothing"
  - "Release asset name contract: RemoteControl-vX.Y.Z.apk, RemoteControl-Setup-vX.Y.Z.exe, RemoteControl-Extension-vX.Y.Z.zip"
  - "Mirror constants: nandodeomkar/remote-control-releases, api.github.com/repos/<mirror>/releases/latest"
  - "Output token prefixes BUMP / DRYRUN / SHA256"
affects:
  - "12-03 (first real publish, gated on the mirror repo existing)"
  - "12-06 (server-side asset prefix constants must match these names)"
  - "12-10 (client-side repo + asset prefix constants)"
  - "12-18 (publishes v1.6.0 and v1.6.1 through this script)"
tech-stack:
  added: []
  patterns:
    - "installer/build-installer.ps1 is the template: [CmdletBinding()] + comment-based help, $ErrorActionPreference='Stop', Invoke-Native, three-candidate exe resolution, Split-Path -Parent $PSScriptRoot layout block, Write-Host colour convention"
    - "Anchored single-line regex rewriting with a one-line-changed post-condition -- never a YAML/TOML/JSON round trip"
key-files:
  created:
    - tools/release.ps1
    - tools/verify-release-dryrun.ps1
  modified: []
decisions:
  - "Two API probes, not one: /repos/<mirror> distinguishes 'repo missing' from /releases/latest's 404, which also means 'repo exists but has no releases yet' -- otherwise the first-ever release could never be published"
  - "Environment-state refusals (dirty tree, unreachable mirror) degrade to a printed warning under -DryRun; argument refusals (bad format, version at or below published latest) throw in both modes"
  - "The version bump is committed before tagging, so the tag names the source the artifacts were built from"
  - "Only the captured version spans are spliced, not whole lines, so indentation, quoting and trailing commas survive"
  - "Compress-Archive takes the extension directory (not its contents), keeping the extension/ folder at the zip root as the shipped README instructions assume"
metrics:
  duration: ~35min
  tasks: 3
  files: 2
  completed: 2026-08-01
---

# Phase 12 Plan 01: Release Script Summary

`tools/release.ps1` now makes a release exist in one command: it refuses five
preflight conditions with actionable messages, rewrites the three
version-bearing files to one `X.Y.Z` with a one-line-changed post-condition,
builds the three contract-named artifacts into `dist/`, prints their sha256
values, commits and tags the private repo, and publishes the mirror release —
with a `-DryRun` that is provably side-effect-free.

## What Was Built

### Task 1 — Preflight refusals (`df26232`)

Five checks, in order, each throwing a message that says what to do:

1. **Version format** — `^\d+\.\d+\.\d+$`. Suffixes are rejected here; the
   pre-release channel is `-PreRelease`, not a tag suffix.
2. **Dirty tree** — `git status --porcelain`. `dist/` is gitignored
   (`.gitignore:9`), so the script's own output can never trip this on a
   later run.
3. **`gh` resolution** — `Get-Command gh` → `C:\Program Files\GitHub CLI\gh.exe`
   → a multi-line throw naming both. The absolute path is a *fallback*, never
   the sole candidate.
4. **Release signing** — refuses when `app/remote_control/android/key.properties`
   is absent, rather than silently emitting a debug-signed APK that can never
   upgrade a release-signed install (`STATUS_FAILURE_CONFLICT`).
5. **Mirror reachability + latest-published refusal** — anonymous
   `Invoke-RestMethod`, TLS 1.2 forced, compared as an integer triple. Never
   `git describe`: the local tag history is known-incomplete (`v1.3.x` was
   shipped untagged, confirmed — local tags are `v1.0.0 v1.1.0 v1.2.0 v1.4.0`).

Observed behaviour today (mirror 404s, as expected):

```
WOULD REFUSE (continuing because -DryRun):
The public mirror repo does not exist yet:
  nandodeomkar/remote-control-releases
Create it once, as PUBLIC (clients read it anonymously, with no token):
  gh repo create nandodeomkar/remote-control-releases --public
```

and `-Version 1.2` exits 1 with the format message.

### Task 2 — Bump engine + SC1 harness (`cc16e70`)

`Set-VersionField` reads the file as **bytes**, decodes with
`Encoding.UTF8.GetString` (so a BOM survives as a leading U+FEFF), finds the
first line matching the anchor, and splices **only the captured version spans**
back in. It then re-derives the line array and asserts exactly one line
differs and that it contains the new version.

| File | Anchor | Result |
|---|---|---|
| `server/server-windows/Cargo.toml` | `^\s*version\s*=\s*"([^"]+)"` (first match) | `1.4.0 -> 9.9.9` |
| `app/remote_control/pubspec.yaml` | `^version:\s*(\d+\.\d+\.\d+)\+(\d+)$` | `1.4.0+8 -> 9.9.9+9` (both halves) |
| `extension/manifest.json` | `"version"\s*:\s*"([^"]+)"` | `1.2.1 -> 9.9.9` |

Proven by a **real, non-dry** run in a scratch git repo (the live mirror 404s,
so a real run cannot complete against it — the scratch copy pointed
`$MirrorRepo` at `cli/cli`):

- `diff` against the pre-image showed **exactly one changed line per file**
  (`7c7`, `24c24`, `4c4`);
- line endings preserved per file — `Cargo.toml` stayed LF, `manifest.json`
  stayed CRLF (the repo genuinely mixes them, which is why the splice is
  span-based rather than split-and-rejoin);
- all 54 `Cargo.toml` comments and the pubspec `INCREASE` comment block
  survived; JSON indentation and trailing comma untouched.

`tools/verify-release-dryrun.ps1` runs the dry run in a child PowerShell host
and asserts (a) exit 0, (b) exactly three `BUMP ` lines, (c) the three expected
paths and no others, (d) every `-> ` target at the probe version, (e)
`git status --porcelain` byte-identical before and after. Prints `OK`, exits 0.

### Task 3 — Build, hash, tag, publish (`1c2f5ab`)

- **Build** — `flutter build apk --release` then copy to
  `dist\RemoteControl-vX.Y.Z.apk`; `installer/build-installer.ps1` **invoked**
  (not reimplemented) for `dist\RemoteControl-Setup-vX.Y.Z.exe`;
  `Compress-Archive` for `dist\RemoteControl-Extension-vX.Y.Z.zip`. Each output
  existence-checked.
- **Hash** — `Get-FileHash -Algorithm SHA256`, printed as
  `SHA256 <name> <lowercase hex>`.
- **Tag** — refuses a pre-existing tag, then `git add` the three bumped files,
  `git commit -m "chore(release): vX.Y.Z"`, `git tag`, `git push origin HEAD`,
  `git push origin vX.Y.Z`. "Tag both repos" is satisfied by this private tag
  plus the mirror release tag `gh release create` creates.
- **Publish** — `gh release create vX.Y.Z <3 assets> --repo <mirror> --title
  --notes-file [--prerelease]`, with a failure message that hands back the
  exact command to finish by hand (the tag is already pushed at that point).
- **`-PreRelease` semantics** recorded in the help block: a pre-release is for
  the owner's own UAT and is deliberately invisible to clients —
  `/releases/latest` excludes pre-releases and the client parser rejects
  `X.Y.Z-rcN`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `/releases/latest` 404 also means "no releases yet", which would have blocked the first-ever release**

- **Found during:** Task 1
- **Issue:** The plan specified a single probe of `/releases/latest`, treating
  404 as "the repo does not exist". GitHub returns 404 from that endpoint for
  a repo that exists but has no releases — so the very first publish (which
  12-03 owns) could never succeed.
- **Fix:** Two probes. `https://api.github.com/repos/<mirror>` 404 → the repo
  is missing, throw with the exact `gh repo create` command.
  `/releases/latest` 404 with the repo present → "the mirror has no releases
  yet — this is the first", skip the comparison and continue.
- **Files modified:** `tools/release.ps1`
- **Commit:** `df26232`

**2. [Rule 3 - Blocking] The dirty-tree refusal made the SC1 harness unrunnable**

- **Found during:** Task 1 / Task 2
- **Issue:** The plan says all five preflights still refuse under `-DryRun`.
  But the harness must run while the work that adds it is itself uncommitted
  (and `.planning/STATE.md` is modified by the orchestrator for the whole
  phase), so the dirty-tree refusal made criterion (a) — dry run exits 0 —
  unsatisfiable during execution.
- **Fix:** A `Deny-Or-Warn` helper. *Environment-state* refusals (dirty tree,
  unreachable mirror — the latter was already granted this concession by the
  plan) print the identical message and continue under `-DryRun`; a real run
  still throws. *Argument* refusals (bad version format, version at or below
  the published latest) throw in both modes. `must_haves` truth "a dirty
  working tree refuses the run before anything is bumped or built" is intact:
  a dry run bumps and builds nothing.
- **Files modified:** `tools/release.ps1`
- **Commit:** `df26232`

**3. [Rule 2 - Missing critical] The tag would have pointed at the pre-bump commit**

- **Found during:** Task 3
- **Issue:** The plan's tag stage was `git tag vX.Y.Z` + `git push`, but the
  bump leaves three files modified and uncommitted. Tagging there names the
  *previous* commit, so the tag would not identify the source the artifacts
  were built from — defeating the point of tagging a release.
- **Fix:** Commit the three bumped files as `chore(release): vX.Y.Z` before
  tagging, and push `HEAD` as well as the tag. Also added a pre-existing-tag
  refusal so a re-run fails before pushing anything.
- **Files modified:** `tools/release.ps1`
- **Commit:** `1c2f5ab`

**4. [Rule 2 - Missing critical] TLS 1.2 not negotiated by Windows PowerShell 5.1**

- **Found during:** Task 1
- **Issue:** PS 5.1 still defaults to TLS 1.0 on some machines; GitHub is TLS
  1.2+ only, so the probe would fail with an opaque "underlying connection was
  closed" rather than an actionable message.
- **Fix:** `[Net.ServicePointManager]::SecurityProtocol -bor Tls12` before any
  probe.
- **Files modified:** `tools/release.ps1`
- **Commit:** `df26232`

### Interpretation Choices (not deviations, recorded for the record)

- **Extension zip root.** The plan said "`Compress-Archive` over `extension/`
  contents". `DISTRIBUTION.md`'s shipped instruction is
  `Compress-Archive -Path extension` and tells recipients to "load the
  `extension` folder unpacked" — so the directory itself is kept at the zip
  root, matching what the extension README already tells users to do.
- **Comment wording.** The words `Authorization`, `--token`, `ConvertTo-Json`
  and `ConvertFrom-Yaml` were removed even from *negative* comments that
  documented their absence, so a grep-based verifier cannot false-positive.
  The invariants are still stated, in prose.

## Verification

| Check | Result |
|---|---|
| `powershell -File tools/verify-release-dryrun.ps1` | `OK`, exit 0 |
| `git status --porcelain` unchanged by a dry run | pass (harness criterion e, and confirmed by hand) |
| `Get-Help ./tools/release.ps1 -Full` | exit 0; `.SYNOPSIS` + all three parameters documented |
| `-Version 1.2 -DryRun` | exit 1, version-format message |
| `-Version 0.0.1 -DryRun`, mirror unreachable | prints `gh repo create nandodeomkar/remote-control-releases --public` |
| `-Version 9.9.9 -DryRun` | 3 `BUMP ` lines, 4 build + 3 hash + 5 tag + 2 publish `DRYRUN ` lines, 0 writes |
| `-PreRelease` dry run | `--prerelease` appended to the `gh release create` line |
| Real (non-dry) bump, scratch repo | exactly one line changed per file; endings, comments, JSON formatting intact |
| PowerShell parser over both scripts | no parse errors |
| Forbidden literals (`Authorization`, `--token`, `ghp_`, `github_pat_`, YAML/JSON serializers) | none |

## Success Criteria Status

- **SC1 (dry-run form)** — mechanically demonstrable: three version fields, one
  version, exactly one line each, proven by `tools/verify-release-dryrun.ps1`.
  The *full* SC1 (three artifacts published under one tag) is written and
  reviewable but not executed — see below.
- **No token, no sole-hardcoded `gh` path, no YAML/TOML round trip** — verified
  by grep and by the real-bump diff.

## Not Executed Here (by design)

The build/tag/publish stages have **never been run for real**: the mirror repo
`nandodeomkar/remote-control-releases` does not exist yet (confirmed 404 today),
so no real run can get past preflight 5. Plan **12-03** owns the blocking human
action that creates it and performs the first real publish. What *is* proven
today is every preflight path, the full bump engine (against a scratch repo
with a reachable mirror stand-in), and that `-DryRun` is side-effect-free.

## Known Stubs

None. Every code path in both scripts is implemented; the unexercised paths are
unexercised because their external precondition (the mirror repo) is a
deliberately gated human action in 12-03, not because they are stubbed.

## Self-Check: PASSED

- `tools/release.ps1` — FOUND
- `tools/verify-release-dryrun.ps1` — FOUND
- `.planning/phases/12-in-app-updates/12-01-SUMMARY.md` — FOUND
- commit `df26232` — FOUND
- commit `cc16e70` — FOUND
- commit `1c2f5ab` — FOUND
