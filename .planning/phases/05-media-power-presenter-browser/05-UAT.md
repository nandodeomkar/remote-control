---
status: testing
phase: 05-media-power-presenter-browser
source: [05-VERIFICATION.md]
started: 2026-07-11T06:40:00Z
updated: 2026-07-11T06:40:00Z
---

## Current Test

number: 1
name: Media transport controls whatever is playing system-wide (MED-01, SC1)
expected: |
  Play/pause, next, prev act on Spotify AND a YouTube browser tab — whatever is currently playing responds
awaiting: user response

## Tests

### 1. Media transport controls whatever is playing system-wide (MED-01, SC1)
expected: Play/pause, next, prev act on Spotify AND a YouTube browser tab — whatever is currently playing responds
result: [pending]

### 2. Volume slider is absolute and PC-side changes follow (MED-02, SC1)
expected: Dragging the slider sets exact PC volume (finger wins during drag); changing volume with the PC keyboard/mixer moves the app slider within ~250ms; mute reflects PC state
result: [pending]

### 3. Lock and sleep execute after slide-to-confirm; sleep SUSPENDS not hibernates (PWR-01/02, SC2)
expected: Completed slide locks the PC; completed sleep slide suspends (fans off, instant resume) — NOT hibernate; session recovers on wake
result: [pending]

### 4. Restart/shutdown require slide PLUS dialog confirm — no single-action path (PWR-03, SC3)
expected: Restart/shutdown show the red countdown dialog and fire ONLY on its confirm press; letting it reach 0 cancels; a partial slide springs back sending nothing; the PC actually reboots/powers off
result: [pending]

### 5. Presenter drives slides + blank in PowerPoint with an elapsed timer (PRES-01/02, SC4)
expected: Start show (F5), tap zones advance/retreat slides, Blank (B), End show (Esc) drive a focused PowerPoint/Impress slideshow; the timer runs, pauses on tap, resets on hold; screen stays awake
result: [pending]

### 6. Browser macros act on the focused browser incl. zoom (BROW-01, SC5)
expected: Back/forward, new/close tab, refresh, zoom in/out act on the focused browser window; zoom chord (Ctrl+Plus/Minus) actually zooms
result: [pending]

## Summary

total: 6
passed: 0
issues: 0
pending: 6
skipped: 0
blocked: 0

## Gaps
