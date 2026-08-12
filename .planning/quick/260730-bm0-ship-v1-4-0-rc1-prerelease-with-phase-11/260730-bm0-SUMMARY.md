---
phase: quick-260730-bm0
plan: 01
status: complete
subsystem: release
tags: [release, versioning, installer, apk, extension, github]
requires: [phase-11 waves 1-6]
provides: "GitHub prerelease v1.4.0-rc1 carrying phase-11 bookmarks, all three parts version-distinguishable from v1.3.2"
affects: [server/server-windows/Cargo.toml, server/Cargo.lock, app/remote_control/pubspec.yaml, extension/manifest.json]
tech-stack:
  added: []
  patterns: ["grep -a binary search with a positive control instead of strings(1)"]
key-files:
  created:
    - dist/RemoteControl-Setup-v1.4.0-rc1.exe
    - dist/RemoteControl-v1.4.0-rc1.apk
    - dist/RemoteControl-Extension-v1.4.0-rc1.zip
  modified:
    - server/server-windows/Cargo.toml
    - server/Cargo.lock
    - app/remote_control/pubspec.yaml
    - extension/manifest.json
decisions:
  - "Extension manifest went 1.1.0 -> 1.2.0 (not 1.4.0): the manifest version is the friend-visible reload receipt in chrome://extensions, independent of the release version. Asset filename tracks the release (v1.4.0-rc1), per precedent."
  - "Release notes corrected on two points before publishing: the v1.3.0 back-link was made an absolute URL (relative links do not resolve in a GitHub release body), and the extension-reload claim was split to cover self-extracted-zip users, who would otherwise reload a stale directory with no error explaining why."
metrics:
  duration: ~12min
  completed: 2026-07-30
---

# Quick 260730-bm0: Ship v1.4.0-rc1 Prerelease with Phase 11 Summary

Published GitHub prerelease **v1.4.0-rc1** carrying the phase-11 bookmarks feature, with all three shipped parts rebuilt and each one *proven* to be the new build before anything was uploaded.

## What Shipped

Release: <https://github.com/nandodeomkar/remote-control/releases/tag/v1.4.0-rc1>
Title: `Remote Control v1.4.0-rc1 (phase 11 test build)` — flagged **prerelease**, target `master`.

| Asset | Size |
|-------|------|
| `RemoteControl-Setup-v1.4.0-rc1.exe` | 5,176,007 bytes (4.94 MB) |
| `RemoteControl-v1.4.0-rc1.apk` | 69,630,939 bytes |
| `RemoteControl-Extension-v1.4.0-rc1.zip` | 12,015 bytes |

Tag resolves to commit **`2fca0cbac6652c8014d941e7318b54bb9489f39c`** — the version-bump commit itself, so the tag captures the exact code state that produced the artifacts.

## Version Bumps (one commit, `2fca0cb`)

| File | From | To |
|------|------|-----|
| `server/server-windows/Cargo.toml` | `1.3.2` | `1.4.0` |
| `server/Cargo.lock` (`server-windows` entry) | `1.3.2` | `1.4.0` |
| `app/remote_control/pubspec.yaml` | `1.3.2+6` | `1.4.0+7` |
| `extension/manifest.json` | `1.1.0` | `1.2.0` |

Four one-line changes, nothing else — `git diff --stat` showed `4 files changed, 4 insertions(+), 4 deletions(-)`. `cargo metadata` rewrote the lockfile (it exited 101 on the offline registry check, but the rewrite still landed and was diff-verified as a single version line). `cargo test -p server-core --test extension_guard` passed 4/4, proving the manifest edit left valid JSON with the `bookmarks` permission intact.

## Identity Gates — the point of the exercise

The pre-existing exe contained **zero** phase-11 support, so "did the rebuild actually take" was the real risk. All three gates ran twice: once after building, once again immediately before `gh release create`.

### G1 — server exe contains phase 11

`grep -ac` against the binary directly. `strings` is not installed here, so a `strings | grep -c` pipeline would print `0` regardless of truth — a silent false negative in both directions.

| Message | Baseline (pre-rebuild) | Rebuilt exe |
|---------|------------------------|-------------|
| `bm.list` | 0 | **1** |
| `bm.changed` | 0 | **1** |
| `bm.open` | 0 | **1** |
| `bm.star` | 0 | **1** |
| `bm.unstar` | 0 | **1** |
| `bm.remove` | 0 | **1** |
| `tabs.activate` *(positive control)* | 1 | 1 |

The control held at 1 on both files while all six `bm.*` flipped 0 → 1. That is what makes the result meaningful: the search method demonstrably works on this file format, so the six zeros were a real absence and the six ones are a real presence.

### G2 — APK version identity

```
package: name='dev.omkar.remotecontrol' versionCode='7' versionName='1.4.0' platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36' compileSdkVersionCodename='16'
```

No Gradle-cache staleness, so no `flutter clean` was needed. Corroborating signal: the APK is 69,630,939 bytes against v1.3.2's 69,595,743 — a genuinely different binary, not a re-copy.

### G3 — APK is release-signed

```
V2 Signer: certificate DN: CN=Omkar Nandode, OU=Revamp, O=Harmonic Mean, L=unknown, ST=unknown
V2 Signer: certificate SHA-256 digest: 957e5a25d908d9de6d12fe427cb2ef5e91e9994a91b8643e9e31c8b919050d23
```

Exact match to the release keystore digest — not the debug key, so it will upgrade over friends' existing installs.

The extension zip carries the expected three-entry layout (`extension\background.js`, `extension\manifest.json` at 360 bytes with the fresh 08:36 timestamp, `extension\README.md`).

## Push Before Tag

Local `master` was **55 commits ahead** of `origin/master` — every phase-11 commit was unpushed. Since `gh release create` without `--target` tags the remote default branch's current HEAD, publishing first would have hung the tag on `06fe04f`, a commit predating the entire feature. Pushed `06fe04f..2fca0cb` first and confirmed `origin/master..master` was empty before creating the release.

## Deviations from Plan

Two corrections to the `release_notes` body, both directed by the owner before publishing, both fixing statements that would have misled a non-technical installer:

**1. [Rule 1 - Bug] Relative back-link replaced with an absolute URL**
- **Found during:** Task 3
- **Issue:** The "First time here?" line linked to `../../releases/tag/v1.3.0`. Relative links do not resolve reliably in a GitHub release body.
- **Fix:** Target changed to `https://github.com/nandodeomkar/remote-control/releases/tag/v1.3.0`.

**2. [Rule 2 - Missing critical info] Extension-reload instruction split by install path**
- **Found during:** Task 3
- **Issue:** The notes asserted "The setup exe already put the new files in place, so a reload is all that is needed." That only holds if Chrome's unpacked-extension path points at the installer's bundled copy. A friend who originally extracted a zip to a directory of their own choosing would reload stale files and see nothing, with no error explaining why.
- **Fix:** Reworded to cover both paths — installer users just reload; self-extracted-zip users must replace their files with the `RemoteControl-Extension-v1.4.0-rc1.zip` contents *before* reloading, with the tell being that the version still reads 1.1.0. Plain register preserved, not turned into a troubleshooting matrix.

Otherwise executed exactly as written. No `dist/` artifact was ever staged (`.gitignore:9` → `/dist/`); `README.md`, `DISTRIBUTION.md`, `extension/README.md` and `ROADMAP.md` are untouched, since phase-11 documentation prose belongs to plan 11-12.

## Caveats to Carry Forward

- **The repo is private.** Friends need repo access to download release assets, otherwise the owner hands them the three files directly. The v1.3.0-rc1 prerelease had the same shape.
- **Phase 11's on-device UAT (plan 11-12) has not run.** That is precisely why this is a prerelease rather than a release.
- **Known rough edge documented in the notes:** press-and-hold on a tab's star also switches to that tab (phase-11 deferred item 2 — benign, star still fires exactly once).
- Version bumps were behaviour-neutral: no test anywhere pins any of the three version strings, so no full-suite re-run was required.

## Self-Check: PASSED

- `dist/RemoteControl-Setup-v1.4.0-rc1.exe` — FOUND (5,176,007 bytes)
- `dist/RemoteControl-v1.4.0-rc1.apk` — FOUND (69,630,939 bytes)
- `dist/RemoteControl-Extension-v1.4.0-rc1.zip` — FOUND (12,015 bytes)
- Commit `2fca0cb` — FOUND, present on `origin/master`
- Release `v1.4.0-rc1` — FOUND, `isPrerelease=true`, exactly 3 assets, all `state=uploaded`
- Working tree clean; temp notes file removed from the scratchpad
