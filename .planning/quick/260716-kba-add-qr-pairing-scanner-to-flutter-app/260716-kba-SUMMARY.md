---
quick_id: 260716-kba
type: quick
requirements: [CONN-02]
dependency-graph:
  requires:
    - "pair_window.rs rc://pair QR payload (876beb4)"
    - "PairingSheet _submit/_pendingPin retry model (03-06)"
    - "ConnectionService.connectTo RFC1918 dial guard (03-05)"
  provides:
    - "PairQrData + parsePairQr strict rc://pair validation"
    - "QrScanScreen full-screen scanner route + QrScanErrorPanel"
    - "Scan QR secondary affordance on the pairing sheet"
  affects:
    - "app/remote_control pairing flow (additive — manual PIN entry unchanged)"
tech-stack:
  added:
    - "mobile_scanner 7.2.1 (verified publisher steenbakker.dev)"
  patterns:
    - "injected scanQr seam on PairingSheet (house constructor-injection)"
    - "camera-free QrScanErrorPanel extraction for widget-testability"
key-files:
  created:
    - app/remote_control/lib/net/pair_qr.dart
    - app/remote_control/lib/screens/qr_scan_screen.dart
    - app/remote_control/test/pair_qr_test.dart
    - app/remote_control/test/qr_scan_pairing_test.dart
  modified:
    - app/remote_control/pubspec.yaml
    - app/remote_control/android/app/src/main/AndroidManifest.xml
    - app/remote_control/android/build.gradle.kts
    - app/remote_control/android/.gitignore
    - app/remote_control/lib/screens/connection_copy.dart
    - app/remote_control/lib/screens/pairing_dialog.dart
    - app/remote_control/test/pairing_flow_test.dart
decisions:
  - "Matched scan (host+port == sheet target) fills the field and calls the EXISTING _submit — byte-identical to typing, including lockout no-op"
  - "Mismatched scan parks the pin as _pendingPin and fires a manual-key connectTo — the existing didUpdateWidget needPin hook auto-feeds it, zero new plumbing"
  - "AGP 9 + mobile_scanner 7.2.x: apply org.jetbrains.kotlin.android to the :mobile_scanner subproject from the root gradle script (Flutter template pins android.builtInKotlin=false)"
metrics:
  duration: ~22min
  completed: 2026-07-16
  tasks: 3
  tests: "454 total green (23 parser + 8 routing new)"
---

# Quick Task 260716-kba: Add QR Pairing Scanner to Flutter App Summary

QR pairing scanner: scan the PC pair window's rc://pair QR to feed host/port/pin into the EXISTING pairing flow via mobile_scanner 7.2.1 — zero typing, manual PIN entry untouched.

## What Was Built

- **`lib/net/pair_qr.dart`** — `PairQrData` (value-equal, deliberately NO toString override so the pin can never leak, T-QR-02) + `parsePairQr`, whitelist-strict per T-QR-01: `rc` scheme, `pair` authority, IP-literal host (`InternetAddress.tryParse`, same rule as Connect-by-IP), port 1..65535, exactly-6-digit pin. Anything else → null (malformed).
- **`lib/screens/qr_scan_screen.dart`** — dark-minimal full-screen `MaterialPageRoute<PairQrData>` scanner: QR-only formats, pop-once `_done` guard, reserved fixed-height malformed line (`kQrMalformedCopy`, 2s DateTime cooldown, scanning continues), and the public camera-free `QrScanErrorPanel` (permissionDenied → `kCameraDeniedCopy` with `Symbols.no_photography_rounded`; anything else → `kCameraErrorCopy` with `Symbols.videocam_off_rounded`).
- **`pairing_dialog.dart`** — `PairingSheet` gained `targetHost`/`targetPort`/`onConnectScanned`/`scanQr` (injected seam). `_scan()`: matched target fills `_pinCtrl` and calls the existing `_submit()` (lockout gate holds — field fills, countdown explains); different target parks `_pendingPin` and fires `onConnectScanned` — the existing needPin-transition hook auto-feeds. `showPairingSheet` wires the real route + `manualDeviceKey` connectTo (scanned host still crosses the RFC1918 guard). Scan QR renders as a TextButton.icon below the Pair CTA (D-03 secondary style).
- **`connection_copy.dart`** — six new locked-tone constants (`kScanQrLabel/Title/Hint`, `kQrMalformedCopy`, `kCameraDeniedCopy`, `kCameraErrorCopy`).
- **Android** — `CAMERA` uses-permission (mobile_scanner requests the runtime grant itself); `mobile_scanner: ^7.2.1` in pubspec.
- Expired-PIN needed ZERO new code: server `authFail{pinExpired}` renders the existing 'That PIN expired' line — pinned by the round-trip test.

## Commits

| Commit | Type | Description |
|--------|------|-------------|
| 1de6b73 | test | Failing rc://pair parser table (RED) |
| 483b2d6 | feat | Parser + mobile_scanner dep + CAMERA permission (GREEN) |
| fb4a041 | feat | QrScanScreen route + Scan QR affordance + sheet wiring |
| ed72b64 | test | Seven scan-routing widget tests + AGP9 KGP fix |
| 9746057 | chore | Ignore stray android/build gradle-report output |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] mobile_scanner 7.2.1 gradle failure on AGP 9**
- **Found during:** Task 3 (release build sanity check)
- **Issue:** `Could not find method kotlin()` at mobile_scanner's build.gradle:97. The package applies `kotlin-android` only on AGP < 9, expecting AGP 9's built-in Kotlin — but the Flutter template pins `android.builtInKotlin=false`, and Flutter's KGP auto-apply skips the project because the runtime-conditional `apply plugin: 'kotlin-android'` line matches its textual detection.
- **Fix:** In `android/build.gradle.kts`, apply `org.jetbrains.kotlin.android` to the `:mobile_scanner` subproject via `plugins.withId("com.android.library")` — KGP lands before the plugin's `kotlin {}` block evaluates. Idempotent; removable once mobile_scanner supports AGP 9 with built-in Kotlin disabled. (Flipping `android.builtInKotlin=true` was rejected: Flutter's tooling applies KGP to `:app`, which conflicts with built-in Kotlin.)
- **Files modified:** app/remote_control/android/build.gradle.kts
- **Commit:** ed72b64

**2. [Rule 3 - Untracked generated output] stray `android/build/` directory**
- **Found during:** Task 3 commit (post-build `git status`)
- **Issue:** Gradle wrote problem-report output to `android/build/` (the real build dir is redirected to `../../build`, already ignored) — left untracked.
- **Fix:** Added `/build/` to `android/.gitignore`.
- **Commit:** 9746057

## TDD Gate Compliance

- Task 1: RED (1de6b73, compile-fail + full table) → GREEN (483b2d6, 23/23).
- Task 3: tests written against the Task-2 implementation as pinning tests (green on first run by plan design — the plan's own action expects "after the new file is green, run the FULL suite").

## Verification

- `flutter analyze` — clean.
- `flutter test` — 454 tests green: 23-case parser table, 8 scan-routing cases, updated pairing_flow suite, icons_guard + theme_tokens_guard over the new files.
- `flutter build apk --release` — builds (65.9MB; mobile_scanner bundles the MLKit barcode model — the unbundled Play-services variant is available via a gradle.properties flag if size ever matters).
- grep checks: CAMERA permission present; no classic `Icons.` refs and no banned hex literals in the new lib files; no print/log of pin or raw QR content in pair_qr.dart / qr_scan_screen.dart / pairing_dialog.dart.
- On-device end-to-end scan (live QR, expired re-scan) remains a post-merge dogfood item per the plan — not a gate here.

## Known Stubs

None.

## Threat Flags

None — both trust boundaries (camera → app, app → LAN) are in the plan's threat model; T-QR-01/02/SC mitigations implemented, T-QR-03 accepted as planned.

## Self-Check: PASSED

All 5 created/summary files present on disk; all 5 commit hashes (1de6b73, 483b2d6, fb4a041, ed72b64, 9746057) verified in git log.
