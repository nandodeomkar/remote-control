---
phase: 06-apps-clipboard
plan: 07
subsystem: verification
tags: [uat, on-device, regression-floor, security, apps, clipboard]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    plan: 02
    provides: "WinApps — real window enumeration + icons + focus/close/launch on the apps thread"
  - phase: 06-apps-clipboard
    plan: 03
    provides: "Apps screen (favorites grid + live open-windows list) + hub tile"
  - phase: 06-apps-clipboard
    plan: 04
    provides: "WinClipboard + clip.changed push + server-side sensitive/large/echo skip"
  - phase: 06-apps-clipboard
    plan: 05
    provides: "Clipboard screen (Send/Fetch + last-5 history)"
  - phase: 06-apps-clipboard
    plan: 06
    provides: "Opt-in auto-sync (live apply + resume-sync + echo suppression)"
provides:
  - "Green automated regression floor (cargo --workspace + server-windows build + dart + flutter)"
  - "On-device UAT sign-off (SC1-SC5 + wire-size guard) recorded in 06-UAT.md"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns: []

key-files:
  created:
    - ".planning/phases/06-apps-clipboard/06-UAT.md"
  modified: []

key-decisions:
  - "Root-caused a false UAT failure to a stale pre-Phase-6 APK: `flutter install` reinstalled a Jul-11 artifact without recompiling. Fixed with an explicit `flutter build apk --release` (Gradle assembleRelease, 72s) + reinstall + clean server restart. All apps/clipboard features then worked."
  - "Owner deferred the sensitive-clip-skip gap (T-06-06) as a v1 limitation rather than blocking the phase."
---

## Summary

Phase-6 close-out gate. Task 1 (automated regression floor) and Task 2 (on-device UAT) both ran; the phase's features are built, and 5 of 6 on-device criteria pass. One security limitation was found and owner-acknowledged (deferred, not fixed).

## Task 1 — Automated regression floor: GREEN

- `cargo test --workspace`: server-core (92 lib + 6 fixtures + 19 integration incl. apps_/clip_ push tests) + server-windows 19 (incl. `apps_filter`, `clip_gate`, `clip_echo`) — all pass.
- `cargo build -p server-windows --release`: clean.
- `dart test` (remote_protocol): 10 pass (incl. `window_info` group).
- `flutter test` (remote_control): 317 pass.

## Task 2 — On-device UAT (Xiaomi 25080RABDI / Android 16 + Windows 11): 5/6 pass

| # | Criterion | Result |
|---|-----------|--------|
| 1 | SC1 / APPS-01 — open-windows list, focus, close, stale-row toast | pass |
| 2 | SC2 / APPS-02 — pin classic app, relaunch, UWP non-pinnable | pass |
| 3 | SC2 / APPS-03 — live window-list refresh (apps.changed) | pass |
| 4 | SC3 / CLIP-01/02 + SC5 / CLIP-04 — send / fetch + history re-push | pass |
| 5 | SC4 / CLIP-03 — auto-sync live/resume/no-loop/**sensitive skip** | ISSUE (limitation) |
| 6 | Wire-size guard — many windows, session survives | pass |

## Issue / Known Limitation (owner-deferred)

**Sensitive-clip skip is source-app dependent (T-06-06).** With auto-sync ON,
copying a password from a browser in-page password manager (tested: Comet,
Chrome) synced the secret to the phone. The server-side skip (06-04) only
withholds clipboard content tagged with the Windows clipboard-exclusion format;
browser managers do not set it. Verified-good managers (KeePassXC / Windows
Credential Manager) were unavailable on the test machine, so the intended-good
path and the live/resume/no-loop sub-checks of SC4 are only PARTIALLY tested.
Owner accepted this as a v1 limitation; fix deferred (background task created).
**T-06-06 is only partially mitigated on real hardware — carry into
/gsd-secure-phase 6.**

## Self-Check: PASSED (regression floor green; UAT recorded; limitation documented)
