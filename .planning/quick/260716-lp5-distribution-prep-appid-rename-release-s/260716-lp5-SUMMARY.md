---
status: complete
quick_id: 260716-lp5
type: quick
subsystem: distribution
tags: [android, signing, packaging, docs, release]
requires: []
provides:
  - "Android app identity dev.omkar.remotecontrol (applicationId + namespace + Kotlin package)"
  - "Existence-guarded key.properties release-signing scaffold with debug fallback"
  - "key.properties.template (placeholder-only, secrets never in repo)"
  - "DISTRIBUTION.md: owner build steps, friend install steps, draft v1.0 release notes"
affects: [app/remote_control/android, DISTRIBUTION.md]
key-files:
  created:
    - app/remote_control/android/key.properties.template
    - app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/MainActivity.kt (moved)
    - DISTRIBUTION.md
  modified:
    - app/remote_control/android/app/build.gradle.kts
    - app/remote_control/android/app/src/main/AndroidManifest.xml
decisions:
  - "App id locked: dev.omkar.remotecontrol everywhere (applicationId, namespace, Kotlin package dir)"
  - "Signing selection is existence-based: release config when android/key.properties exists, debug fallback otherwise — the scaffold can never break the build"
  - "android/.gitignore already covered key.properties/**/*.jks/**/*.keystore from the Flutter template — verified via git check-ignore, no edit made"
  - "Launcher label humanized to 'Remote Control' (no test pinned the old label)"
metrics:
  duration: ~15min
  tasks: 3
  completed: 2026-07-16
---

# Quick Task 260716-lp5: Distribution Prep (app-id rename + release signing scaffold + DISTRIBUTION.md) Summary

Full Android identity rename to dev.omkar.remotecontrol plus a secret-free key.properties signing scaffold (debug fallback proven live) and a root DISTRIBUTION.md; both release artifacts verified buildable.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Android package identity rename | 0f27ab3 | build.gradle.kts, MainActivity.kt (moved to dev/omkar/remotecontrol/), AndroidManifest.xml |
| 2 | Release signing scaffold (debug fallback, zero secrets) | 5d22ebc | build.gradle.kts, key.properties.template |
| 3 | DISTRIBUTION.md + server release-build verification | 719db3d | DISTRIBUTION.md |

## Verification Results

- `git grep -n "com\.example"` over tracked files: **zero hits** (exit 1).
- `flutter analyze`: clean. `flutter test`: **454/454 green**.
- `flutter build apk --release` with NO key.properties present: **succeeded**
  (debug-signing fallback proven inert-safe); `app-release.apk` exists under the
  new applicationId.
- `git check-ignore`: `android/key.properties` ignored, hypothetical
  `android/keys/test.jks` ignored, `key.properties.template` tracked (intended —
  the `key.properties` gitignore pattern matches the exact filename only).
- No secret anywhere in the diff — template carries placeholders only
  (`REPLACE_WITH_STORE_PASSWORD` etc.); no keystore created, keytool never run.
- `cargo build --release -p server-windows`: **succeeded** (2m 49s);
  `server/target/release/server-windows.exe` exists (9.3 MB). The Phase-10
  shell-redesign contingency did NOT trigger — the redesign was already
  committed (876beb4) and compiles clean in release; the plan's "uncommitted
  WIP" note was stale.
- DISTRIBUTION.md: all three sections present; build commands byte-match the
  verified ones; `keytool -genkey` one-liner documented (1 occurrence).

## Owner Migration Note (IMPORTANT)

The package rename orphans the old `com.example.remote_control` installs on the
owner's two phones — they become separate apps that no longer update. One-time
migration per phone:

1. Uninstall the old app manually.
2. Install the new APK (id `dev.omkar.remotecontrol`).
3. Re-pair with the PC — token storage is per-app-id, so the new install starts
   unpaired. Revoke the stale phone entry in the server's Settings.

This is also documented for the owner in DISTRIBUTION.md Section 1.

## Deviations from Plan

**1. [Stale contingency — no action needed] Shell-redesign build blocker never triggered.**
The plan's Task 3 contingency assumed uncommitted Phase-10 shell-redesign WIP in
the server tree; the redesign was already committed at 876beb4 (in this
worktree's history) and the release build passed. Documented per the
orchestrator's correction; no code deviation.

Otherwise: none — plan executed exactly as written (including the verify-don't-
duplicate gitignore check, which found all three patterns already present).

## Known Stubs

None.

## Threat Flags

None — T-DIST-01 (secret disclosure) mitigated as planned: no keystore, no
password, placeholders only, gitignore coverage mechanically verified.
T-DIST-02/03 handled by documentation in DISTRIBUTION.md as designed.

## Self-Check: PASSED

- FOUND: app/remote_control/android/app/build.gradle.kts (contains dev.omkar.remotecontrol)
- FOUND: app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/MainActivity.kt (package dev.omkar.remotecontrol)
- FOUND: app/remote_control/android/key.properties.template (contains storeFile)
- FOUND: DISTRIBUTION.md (contains keytool -genkey)
- FOUND: server/target/release/server-windows.exe
- FOUND commits: 0f27ab3, 5d22ebc, 719db3d
