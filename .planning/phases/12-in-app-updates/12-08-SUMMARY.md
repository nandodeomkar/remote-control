---
phase: 12-in-app-updates
plan: 08
subsystem: mobile-platform
tags: [android, kotlin, packageinstaller, methodchannel, broadcastreceiver, flutter, self-update]
requires:
  - phase: 12-in-app-updates
    provides: "12-01 tools/release.ps1 -- the release-signed RemoteControl-vX.Y.Z.apk this path installs (sequencing only, D-21; no code dependency)"
provides:
  - "MethodChannel remote_control/installer with canInstall / openInstallPermission / cacheDir / install"
  - "Dart class ApkInstaller in lib/update/apk_installer.dart, with the MissingPluginException no-op contract"
  - "Dart enum InstallOutcome {pendingUserAction, declined, failure} + InstallEvent(status) and the Stream<InstallEvent> outcome seam"
  - "Kotlin InstallResultReceiver -- launches Android's own confirmation dialog from STATUS_PENDING_USER_ACTION"
  - "MainActivity.reportInstallOutcome(outcome, status) -- the receiver's route back to Dart"
  - "Android permission REQUEST_INSTALL_PACKAGES and a non-exported <receiver> entry"
affects:
  - "12-10 (apk_download.dart streams to ApkInstaller.cacheDir() and calls ApkInstaller.install after sha256 verification)"
  - "12-14 (update_providers.dart gates updateApp() on ApkInstaller.canInstall and maps declined back to the available row state)"
  - "12-15 (wires the Update button and the install-permission explainer sheet to this channel)"
  - "12-18 (on-hardware verification of the grant-held and grant-revoked paths)"
tech-stack:
  added: []
  patterns:
    - "A second MethodChannel added inside the EXISTING configureFlutterEngine override, cloning the multicast channel's when/else -> notImplemented shape; the shipped block is byte-unchanged (0 deleted lines in the diff)"
    - "Reverse MethodCall ('outcome') on the same channel as the outcome seam instead of an EventChannel -- one channel name, one Kotlin registration, no stream-handler lifecycle for a stream that emits at most once per install"
    - "Platform-channel test contract: with no handler registered every method no-ops to a SAFE default (canInstall true, cacheDir null), so widget tests never touch the platform"
key-files:
  created:
    - app/remote_control/lib/update/apk_installer.dart
    - app/remote_control/test/update/apk_installer_test.dart
    - app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/InstallResultReceiver.kt
  modified:
    - app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/MainActivity.kt
    - app/remote_control/android/app/src/main/AndroidManifest.xml
key-decisions:
  - "The outcome seam is a reverse MethodCall on remote_control/installer, not an EventChannel: one channel name keeps the acceptance grep at exactly 1 and avoids a second Kotlin registration plus stream-handler lifecycle"
  - "canInstall() returns TRUE (not false) on MissingPluginException, so an off-device host behaves as if the grant is held and the explainer sheet never opens spuriously"
  - "cacheDir() lives on this channel specifically so the 70 MB download needs no path_provider dependency -- the phase's new Dart-package surface stays at exactly one (crypto)"
  - "InstallOutcome has no success member at all: the enum is the enforcement of Pitfall 7, not just a comment. A test asserts the name 'success' is absent"
  - "MainActivity holds the channel in a companion-object reference cleared in onDestroy; the receiver drops outcomes silently when it is null (the app is being replaced -- nothing left to tell)"
  - "EXTRA_STATUS_MESSAGE is read inline inside the single Log.i call, so it cannot be reached from any path that returns to Dart (T-12-06)"
patterns-established:
  - "Platform channel + no-op test contract: clone lib/platform/multicast_lock.dart, one MissingPluginException catch per method, each with a documented safe default"
  - "API-level guards named by pitfall: API 26 for the per-app install grant, API 31 for PendingIntent mutability, API 33 for typed getParcelableExtra"
requirements-completed: [D-19, SC4]
duration: 38 min
completed: 2026-08-01
---

# Phase 12 Plan 08: Android APK Self-Update Channel Summary

**A `remote_control/installer` MethodChannel that stages a verified APK into a `PackageInstaller` session and lets Android show its own confirm dialog — with `declined` as a first-class observable outcome and `success` deliberately absent from the enum.**

## Performance

- **Duration:** 38 min
- **Started:** 2026-08-01T21:29Z
- **Completed:** 2026-08-01T22:07Z
- **Tasks:** 3
- **Files created/modified:** 5

## Accomplishments

- **The capability, not the UI.** `ApkInstaller` exposes exactly four methods and one outcome stream; 12-15 wires a button to it. No download logic and no widgets here.
- **The OS keeps its authority.** The app stages bytes and commits a session; Android decides and shows its own dialog. The legacy `ACTION_INSTALL_PACKAGE` intent was rejected because it returns no outcome at all — and D-19's "a declined dialog returns the row to available" is precisely an outcome requirement.
- **Success is unobservable by construction.** `InstallOutcome` has three members and no `success`. A test asserts the name is absent, so a future contributor cannot quietly add an "installing" flag that a fresh launch would read as stuck.
- **Three API-level guards, each tied to a named pitfall.** `canRequestPackageInstalls()` behind API 26 (minSdk is 24 — it would throw `NoSuchMethodError`), `FLAG_MUTABLE` behind API 31 (`commit()` throws without an explicit mutability flag), typed `getParcelableExtra` behind API 33.
- **The shipped multicast channel was not touched.** `git diff 486f67a HEAD -- MainActivity.kt | grep -c '^-[^-]'` returns **0** — the diff is additive only.

## Task Commits

1. **Task 1: apk_installer.dart + the no-op test contract** — `8d093ce` (feat)
2. **Task 2: MainActivity.kt PackageInstaller session and grant check** — `8971b6e` (feat)
3. **Task 3: InstallResultReceiver and the manifest entries** — `cd78432` (feat)

## Files Created/Modified

- `app/remote_control/lib/update/apk_installer.dart` — `ApkInstaller` (`canInstall`, `openInstallPermission`, `cacheDir`, `install`), `InstallOutcome`, `InstallEvent`, and the broadcast outcome stream fed by a reverse `outcome` MethodCall. File-top doc records why success is not an outcome, why verification is not here, and why the seam is not an `EventChannel`.
- `app/remote_control/test/update/apk_installer_test.dart` — 12 tests in three groups: no-handler defaults, mocked method names/arguments, and each outcome reaching the seam.
- `app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/MainActivity.kt` — second `MethodChannel` inside the existing `configureFlutterEngine`; `installApk()` (createSession → openWrite → **fsync before close** → commit); companion `reportInstallOutcome`; `onDestroy` clears the reference.
- `app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/InstallResultReceiver.kt` — status switch: `STATUS_PENDING_USER_ACTION` launches `EXTRA_INTENT` with `FLAG_ACTIVITY_NEW_TASK`, `STATUS_FAILURE_ABORTED` → `declined`, everything else → `failure(status)`, `STATUS_SUCCESS` logged and documented as rarely observed.
- `app/remote_control/android/app/src/main/AndroidManifest.xml` — `REQUEST_INSTALL_PACKAGES` joins the existing permission block; `<receiver android:name=".InstallResultReceiver" android:exported="false"/>` inside `<application>`.

## Decisions Made

| Decision | Rationale |
|---|---|
| Reverse `MethodCall` seam, not `EventChannel` | One channel name (the acceptance grep demands exactly one), one Kotlin registration, and no stream-handler lifecycle for a stream that fires at most twice per install |
| `canInstall()` → `true` off-platform | A `false` default would open the explainer sheet in every widget test and on every non-Android host; `true` matches the Kotlin API-24/25 answer for the same reason (the grant does not exist there) |
| `install()` args as `{'path': ...}` rather than a bare string | Leaves room for a future `sessionName`/`sizeBytes` without a breaking channel change; the Kotlin side rejects a null/empty path with `result.error("no-path", ...)` |
| `result.success(null)` from `install` means *staged and committed*, not *installed* | `commit()` does not block on the user. The user's answer can only arrive on the outcome seam — conflating the two is exactly the bug Pitfall 6 describes |
| Session abandoned on the failure path | A half-written session otherwise lingers in the system's session list; `abandonSession` is itself wrapped so a double failure cannot crash the activity |
| Companion-object channel reference | A `BroadcastReceiver` is constructed by the system and has no route to the engine otherwise. Cleared in `onDestroy`, and `?.` means a dead engine drops the outcome silently — the correct behaviour when the app is mid-replacement |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Task 2's build gate is unsatisfiable before Task 3 exists**

- **Found during:** Task 2 (MainActivity PackageInstaller session)
- **Issue:** Task 2's acceptance criterion is `flutter build apk --debug` exits 0, but `installApk()` names `InstallResultReceiver::class.java` — a class Task 3 creates. Compiled in isolation, Task 2 cannot build; the two tasks are one compilation unit split across two commits.
- **Fix:** Wrote Task 3's receiver and manifest entries, then ran `flutter build apk --debug` **once** to prove both, then committed Task 2 and Task 3 separately in plan order. Every non-build criterion of Task 2 (grep counts, the untouched multicast block) was verified before the Task 2 commit.
- **Files modified:** none beyond the plan's own file list
- **Verification:** `flutter build apk --debug` → `√ Built build\app\outputs\flutter-apk\app-debug.apk`, run twice (once before and once after the manifest wording fix)
- **Committed in:** `8971b6e` / `cd78432`

**2. [Rule 2 - Missing critical] The plan's `install` handler had no argument validation and no session cleanup**

- **Found during:** Task 2
- **Issue:** RESEARCH Code Example 5 passes a `File` straight into the session with no null/empty check and no `try`, so a malformed argument or an IO error would propagate out of the channel handler and crash the activity, leaving an orphaned session behind.
- **Fix:** `path.isNullOrEmpty()` → `result.error("no-path", ...)`; the whole session sequence wrapped so any exception abandons the session (itself guarded) and returns `result.error("install-failed", ...)`.
- **Files modified:** `MainActivity.kt`
- **Verification:** build passes; the failure path returns a code the Dart row can render rather than terminating the process
- **Committed in:** `8971b6e`

**3. [Rule 2 - Missing critical] `EXTRA_INTENT` can be absent on the pending-user-action branch**

- **Found during:** Task 3
- **Issue:** RESEARCH Code Example 5 uses `confirm?.let { ... }`, which silently does nothing when the extra is missing — the row would sit on `pendingUserAction` forever with no dialog and no terminal event.
- **Fix:** A missing `EXTRA_INTENT` logs a warning and forwards `failure(status)`, so the row always reaches a terminal state.
- **Files modified:** `InstallResultReceiver.kt`
- **Verification:** build passes; the branch is unreachable in normal operation and is a liveness guard, not a feature
- **Committed in:** `cd78432`

**4. [Rule 3 - Blocking] `IntentCompat` would have added an androidx dependency question**

- **Found during:** Task 3
- **Issue:** RESEARCH Code Example 5 uses `androidx.core.content.IntentCompat`, whose presence on this app module's compile classpath is incidental (it arrives transitively through the Flutter embedding, not through a declared dependency).
- **Fix:** A hand-written API-33 guard — typed `getParcelableExtra(name, Intent::class.java)` on TIRAMISU+, the `@Suppress("DEPRECATION")` overload below it. Same semantics, zero new dependencies, consistent with T-12-SC ("no Gradle dependency is added by this plan").
- **Files modified:** `InstallResultReceiver.kt`
- **Verification:** `flutter build apk --debug` exits 0
- **Committed in:** `cd78432`

### Verifier-facing wording adjustments (not behavioural)

- The library doc comment in `apk_installer.dart` originally repeated the literal `remote_control/installer`, making the acceptance grep return 2 instead of 1. Reworded to point at `[ApkInstaller._channel]`; the channel name is now spelled exactly once in the file.
- The manifest comment originally repeated `REQUEST_INSTALL_PACKAGES`, making that grep return 2. Reworded to "the install-packages permission below".
- `EXTRA_STATUS_MESSAGE` was initially read on a continuation line of a two-line `Log.i`; folded into a single logging line so "it appears only on a logging line" is checkable by line-based grep.
- The `<receiver>` was initially written across three lines; collapsed to one so `android:exported="false"` is on the same **line** as the name, not merely the same element.

---

**Total deviations:** 4 auto-fixed (2 missing critical, 2 blocking) + 4 wording adjustments
**Impact on plan:** No scope change. Every fix is a crash-, liveness- or dependency-guard on a path the plan already specified; the file list is exactly the plan's file list.

## Verification

| Check | Command | Result |
|---|---|---|
| Task 1 tests | `flutter test test/update/apk_installer_test.dart` | **12 tests, all passed** (plan required ≥5) |
| `cacheDir()` null with no handler | test `cacheDir() is null, so the caller falls back to systemTemp` | PASS |
| `canInstall()` true with no handler | test `canInstall() is true, so the explainer sheet never opens` | PASS |
| `MissingPluginException` per method | `grep -c` on `apk_installer.dart` | **7** (≥4 required — 4 catches + 3 doc mentions) |
| Channel name spelled once | `grep -c 'remote_control/installer' apk_installer.dart` | **1** |
| STATUS_SUCCESS comment present | `grep -c 'STATUS_SUCCESS' apk_installer.dart` | 2 |
| Debug APK builds | `flutter build apk --debug` | **exit 0** |
| One `configureFlutterEngine`, two channels | `grep -c` on `MainActivity.kt` | **1** and **2** |
| API 26 guards | `grep -c 'Build.VERSION_CODES.O' MainActivity.kt` | **2** |
| Mutability flag, API 31 guarded | `grep -c 'FLAG_MUTABLE' MainActivity.kt` | **1**, on the `SDK_INT >= S` line |
| `fsync` before close | `grep -c 'fsync' MainActivity.kt` | **1**, inside the `openWrite(...).use { }` block |
| Multicast block unchanged | `git diff 486f67a HEAD -- MainActivity.kt \| grep -c '^-[^-]'` | **0 deleted lines** |
| Permission declared once | `grep -c 'REQUEST_INSTALL_PACKAGES' AndroidManifest.xml` | **1** |
| Receiver declared, non-exported | `grep -c 'InstallResultReceiver' AndroidManifest.xml` | **1**, with `android:exported="false"` on the same line |
| Merged manifest carries both | grep of `build/app/intermediates/merged_manifests/debug/.../AndroidManifest.xml` | `android.permission.REQUEST_INSTALL_PACKAGES` and `dev.omkar.remotecontrol.InstallResultReceiver` both present |
| `EXTRA_STATUS_MESSAGE` log-only | `grep -n` on `InstallResultReceiver.kt` | **1 occurrence, line 27, inside `Log.i`** |
| Dart analysis | `flutter analyze lib/update/apk_installer.dart test/update/apk_installer_test.dart` | **No issues found** |
| Whole update suite | `flutter test test/update/` | exit 0 |

## Success Criteria Status

- **Three channel methods on both sides, guarded for API 24 and API 31** — four, in fact (`cacheDir` joined them per the plan). Guards verified by grep and by a successful build.
- **The receiver is non-exported and launches the system confirmation intent** — `android:exported="false"` in both the source and the merged manifest; `STATUS_PENDING_USER_ACTION` adds `FLAG_ACTIVITY_NEW_TASK` and calls `context.startActivity`.
- **A decline is an observable non-error outcome; success is deliberately not one** — `STATUS_FAILURE_ABORTED` → `InstallOutcome.declined` (tested); `InstallOutcome` has no `success` member (tested).

## Issues Encountered

None. The only friction was Task 2's build gate depending on a Task 3 file, handled as deviation 1.

## Known Stubs

None. Every branch on both sides is implemented. What is **not** exercised here is the on-device behaviour of the session itself — RESEARCH rates the `PackageInstaller` flow MEDIUM-HIGH confidence and flags `FLAG_MUTABLE` + `EXTRA_INTENT` as details "to be confirmed the first time the channel is run". 12-18 owns that hardware run, including the revoked-grant path. This is a deliberate phase-level sequencing, not a stub.

## Threat Flags

None. This plan introduces no network surface, no new schema and no new trust boundary beyond the three already registered in the plan's threat model (`app cache file -> installer`, `receiver -> other apps`, `app -> system settings`), all with `mitigate` dispositions that are implemented:

- **T-12-21** — receiver `android:exported="false"` + explicit-component `PendingIntent`. Verified in source and merged manifest.
- **T-12-22** — `FLAG_MUTABLE` is present but the intent names an explicit non-exported component in this package; session id as request code under `FLAG_UPDATE_CURRENT`.
- **T-12-23** — no verification and no fetching on the platform side; the doc comment states the sha256 gate is Dart-side and runs before `install`.
- **T-12-06** — `EXTRA_STATUS_MESSAGE` read only inside `Log.i`; the outcome payload carries `{outcome, status}` only.
- **T-12-25** — no persisted installing flag anywhere; `InstallOutcome` cannot express success.
- **T-12-SC** — zero Dart packages and zero Gradle dependencies added (deviation 4 exists to keep it that way).

## Next Plan Readiness

- **12-10** can call `ApkInstaller().cacheDir()` for the download destination and `install(path)` after `verifyOrDelete`.
- **12-14** can gate `updateApp()` on `canInstall()` and map `InstallOutcome.declined` back to the `available` row state.
- **12-15** has `openInstallPermission()` for the explainer sheet's `Open settings` button.
- **Concern for 12-18:** neither the grant-held nor the grant-revoked path has run on hardware. The first real run should confirm that `commit()` produces `STATUS_PENDING_USER_ACTION` (not an `IllegalArgumentException` about mutability) and that the confirmation `Intent` actually surfaces the dialog.

## Self-Check: PASSED

Files on disk:

- `app/remote_control/lib/update/apk_installer.dart` — FOUND
- `app/remote_control/test/update/apk_installer_test.dart` — FOUND
- `app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/InstallResultReceiver.kt` — FOUND
- `app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/MainActivity.kt` — FOUND (modified)
- `app/remote_control/android/app/src/main/AndroidManifest.xml` — FOUND (modified)
- `.planning/phases/12-in-app-updates/12-08-SUMMARY.md` — FOUND

Commits (worktree branch `worktree-agent-a2b3be4e7ca77acec`, base `486f67a`):

- `8d093ce` — FOUND (apk_installer.dart + test)
- `8971b6e` — FOUND (MainActivity.kt)
- `cd78432` — FOUND (InstallResultReceiver.kt + AndroidManifest.xml)
- `f733bc1` — FOUND (this SUMMARY)

Working tree clean; no file deletions in any commit; STATE.md and ROADMAP.md untouched (orchestrator owns them).

---
*Phase: 12-in-app-updates*
*Completed: 2026-08-01*
