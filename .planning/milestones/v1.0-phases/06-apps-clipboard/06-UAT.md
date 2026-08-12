---
status: complete
phase: 06-apps-clipboard
source: [06-01-SUMMARY.md, 06-02-SUMMARY.md, 06-03-SUMMARY.md, 06-04-SUMMARY.md, 06-05-SUMMARY.md, 06-06-SUMMARY.md]
started: 2026-07-12
updated: 2026-07-12
---

## Current Test

[testing complete]

## Tests

### 1. SC1 / APPS-01 — Open windows: list, focus, close, stale-row toast
expected: |
  Apps screen "Open windows" list shows real windows in Alt-Tab order with icons,
  no ghost/blank/cloaked rows. Tap row → window foregrounds (or taskbar flashes).
  Tap close → window closes. Close a window on PC, tap its stale row →
  "That window is no longer open." toast.
result: pass
note: |
  Initial failure was a stale pre-Phase-6 APK pushed by `flutter install` (Jul-11
  artifact reinstalled without recompile). Fixed by an explicit `flutter build apk
  --release` (Gradle assembleRelease) + reinstall + fresh server restart. Retest passed.

### 2. SC2 / APPS-02 — Pin favorite (classic), relaunch, UWP non-pinnable
expected: |
  Long-press a running CLASSIC app (browser/editor/terminal) → "Pinned {app}" and
  it appears in Favorites. Close that app, tap the favorite → it relaunches.
  Long-press a Store/UWP window → "This app can't be pinned yet." (no pin).
result: pass

### 3. SC2 / APPS-03 — Live window-list refresh (apps.changed)
expected: |
  With the Apps screen open, open and close apps on the PC → the window list
  updates within ~1s via apps.changed, with no manual refresh.
result: pass

### 4. SC3 / CLIP-01/02 + SC5 / CLIP-04 — Send / Fetch + Recent history re-push
expected: |
  Copy text on the phone → tap "Send to PC" → paste on PC shows it ("Sent to PC.").
  Copy text on the PC → tap "Fetch from PC" → paste on phone shows it
  ("Copied to phone."). Both appear in "Recent"; tap a history entry → it
  re-pushes to the PC.
result: pass

### 5. SC4 / CLIP-03 — Auto-sync: live, resume-sync, no-loop, sensitive skip
expected: |
  Turn Auto-sync ON. Copy on the PC → appears on the phone live. Copy on the phone
  while the app is BACKGROUNDED → nothing syncs; foreground the app → the phone
  copy reaches the PC (resume-sync; honesty note visible). A two-way copy does NOT
  bounce back (no loop). Copy from a password manager (KeePassXC / Windows
  Credential Manager) with auto-sync ON → the secret does NOT sync to the phone.
result: issue
reported: "Used it with the Comet password manager and Chrome password manager with auto-sync ON — it copied the passwords to the phone. Owner decision: no changes now; mark as a limitation and a feature not fully tested."
severity: major
security_threat: T-06-06
disposition: acknowledged-limitation (owner-deferred, no fix this phase)
note: |
  Sensitive-clip skip failed for BROWSER-based password managers (Comet, Chrome):
  the copied secret DID reach the phone. The server-side skip (06-04) relies on the
  source app setting the Windows "ExcludeClipboardContentFromMonitorProcessing" /
  clipboard-history-exclusion format; browser in-page password managers do not set
  it, so the server cannot detect the content as sensitive. Verified-good managers
  (KeePassXC / Windows Credential Manager) were NOT available on this machine to
  confirm the intended-good path. The live-sync / resume-sync / no-loop sub-checks
  of this test were NOT independently confirmed by the owner — this SC4 item is only
  PARTIALLY tested. Owner explicitly deferred any fix. T-06-06 therefore remains
  only partially mitigated on real hardware; carry into /gsd-secure-phase.

### 6. Wire-size guard — many windows, session survives
expected: |
  Open many windows (aim for 20–40) → the Apps list still updates and the session
  stays connected (icons 32×32, list capped ≤50, under the 64 KB frame cap).
result: pass

## Summary

total: 6
passed: 5
issues: 1
pending: 0
skipped: 0
blocked: 0

## Gaps

- truth: "With auto-sync ON, copying a secret from a password manager does NOT sync to the phone (sensitive-clip skip, T-06-06)."
  status: failed
  reason: "User reported: browser password managers (Comet, Chrome) DID sync copied passwords to the phone. Server-side skip only catches content marked with the Windows clipboard-exclusion format, which browser in-page managers do not set."
  severity: major
  test: 5
  disposition: acknowledged-limitation
  owner_deferred: true
  artifacts: [server/server-windows/src/clip_thread.rs]
  missing: ["detection of browser-manager secrets that omit the clipboard-exclusion format"]

## Known Limitations (owner-acknowledged, not fixed this phase)

- **Sensitive-clip skip is source-app dependent (SC4 / T-06-06).** Clipboard content
  is only withheld from the phone if the copying app tags it with the Windows
  "exclude from clipboard monitoring/history" format. Managers that set it
  (KeePassXC, Windows Credential Manager) are protected; browser in-page password
  managers (Comet, Chrome) do NOT set it, so their copied passwords sync to the
  phone when auto-sync is on. Owner accepts this for v1. Feature is only partially
  tested (the intended-good KeePassXC/Credential-Manager path was not exercised on
  this machine). Revisit under /gsd-secure-phase 6.
