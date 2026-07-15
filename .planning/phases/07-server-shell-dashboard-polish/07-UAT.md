---
status: testing
phase: 07-server-shell-dashboard-polish
source: [07-VERIFICATION.md]
started: 2026-07-15T13:20:00Z
updated: 2026-07-15T13:20:00Z
---

## Current Test

number: 1
name: Tray survives an Explorer restart
expected: |
  Kill + restart explorer.exe (Task Manager); the Remote Control tray icon
  reappears and its menu (Settings / Pair new / Pause / Quit) still works.
awaiting: user response

## Tests

### 1. Tray survives an Explorer restart
expected: Kill+restart explorer.exe (Task Manager); the tray icon reappears and its menu (Settings/Pair new/Pause/Quit) still works.
result: [pending]

### 2. Pause input keeps the connection alive
expected: With a phone connected, click tray Pause input — cursor/keys stop moving the PC, tray icon turns gray, but the phone stays connected (chip stays green); unpause resumes input without re-pairing.
result: [pending]

### 3. Autostart survives a real reboot
expected: Enable "Start with Windows" in Settings, reboot; server is running in the tray after login. Disable it, reboot again; server does NOT auto-start.
result: [pending]

### 4. Revoked phone is disconnected and must re-pair
expected: With a phone paired+connected, open Settings, click Revoke on that device row; the phone's live session drops immediately and it can only reconnect with a fresh 6-digit PIN (stored token no longer works).
result: [pending]

### 5. Firewall-blocked port shows a startup tray warning with a fix hint
expected: With Windows Firewall on and no allow-rule for the port, start the server; a toast/tray warning tells the owner to allow Remote Control through the firewall, and the tray icon shows the warning (red) state.
result: [pending]

### 6. Port-in-use produces a distinct warning, not a silent crash
expected: Start a second copy (or occupy the port); it surfaces a "port already in use — change it in Settings" toast rather than an unexplained exit.
result: [pending]

### 7. UIPI status shows on the phone instead of failing silently
expected: Focus an elevated (Run-as-admin) window on the PC, then move/click from the phone; within ~250ms the phone shows "Can't control this window — it's running as administrator", auto-dismissing ~4s later, never blocking a touch.
result: [pending]

### 8. Dashboard identity + dark-minimal polish on-device
expected: Home shows 8 tool tiles in a uniform 2×4 grid on #0E0F12 with the #4C8DFF accent; persistent Trackpad quick-bar at the bottom of every tool screen (except Trackpad itself); offline disables the tiles but keeps the settings gear reachable.
result: [pending]

### 9. Haptic toggle + keep-awake behave correctly
expected: Taps/keys tick with haptics ON and go silent with the toggle OFF; screen stays awake during trackpad and presenter use (incl. Presenter→quick-bar→Trackpad→back path) and sleeps normally otherwise.
result: [pending]

### 10. Behavior-sensitive review fixes (CR-01, WR-02, WR-05, WR-08) hold under real conditions
expected: Held keys/modifiers/drag release on screen-pop and mid-drag disconnect (no phantom input); overlapping reconnect dials don't bind to a stale target; a broken GPU/RDP GL stack degrades the settings window without taking the tray down; an alive-but-not-reading client still gets held input released within the CONN-07 10s deadline.
result: [pending]

## Summary

total: 10
passed: 0
issues: 0
pending: 10
skipped: 0
blocked: 0

## Gaps
