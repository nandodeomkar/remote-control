# Phase 10 UAT — keyboard rethink + Shortcuts tile

On-device UAT gate (plan 10-06). Owner device: Xiaomi 25080RABDI. PC: Windows 11.

## Task 1 — Regression + fresh release APK (2026-07-17)

| Check | Result |
|-------|--------|
| `flutter analyze` | ✅ No issues found (44.2s) |
| `flutter test` (full app suite) | ✅ 539 passed, 0 failed |
| `cargo test -p server-windows` | ✅ 38 passed, 0 failed, 2 ignored |

**Fresh APK (stale-APK guard, T-10-08):**

- Built THIS session: 2026-07-17 09:20 IST via `flutter build apk --release` (Gradle `assembleRelease` ran fresh, 88.5s — not a cached reuse)
- Path: `app/remote_control/build/app/outputs/flutter-apk/app-release.apk` (69,366,363 bytes)
- Distribution deviation from plan: instead of `flutter install` over USB, the APK was published as `RemoteControl-v1.3.0-rc1.apk` on GitHub prerelease `v1.3.0-rc1` and installed by the owner from there. Same freshly-built artifact; the fresh-build precondition holds.
- Server side: `RemoteControl-Server-v1.3.0-rc1.exe` built fresh same session (09:19 IST) and published on the same release — required because the 10-01 vocabulary extension is two-sided; an old server would silently drop the 18 new key codes.

## Task 2 — On-device walkthrough (blocking human gate)

Owner's verdict: **"works, its not perfect but it works"**, followed by **"pass"** when asked to
name specific gaps against the checklist — i.e. a batch approval with no itemized defects. The
"not perfect" impression was not tied to any numbered check; no gap-closure plan is scoped from
this gate. If specific irritations surface during daily driving, they enter the backlog as
new items rather than reopening this phase.

| # | Check | Result |
|---|-------|--------|
| 1 | Four pads swipe; tab bar highlights; chips on every pad | ✅ pass (owner batch approval) |
| 2 | Type pad IME raised + extras row; IME lowers on swipe to Arrows | ✅ pass (owner batch approval) |
| 3 | Keys dramatically larger (inverted-T, calculator grid, F-row) | ✅ pass (owner batch approval) |
| 4 | Cross-pad combos (Ctrl-lock + F5, Ctrl+→, arrow autorepeat) | ✅ pass (owner batch approval) |
| 5 | No stuck keys (swipe mid-hold, leave screen mid-hold) | ✅ pass (owner batch approval) |
| 6 | Pad persistence across app restart | ✅ pass (owner batch approval) |
| 7 | Shortcuts tile 3rd; 4 sections; effect labels + chord subtext | ✅ pass (owner batch approval) |
| 8 | Representative chords fire on PC (Win+D, Win+Shift+S, PrtScn, Ctrl+Shift+Esc, Ctrl+C/V, Ctrl+Plus/0) | ✅ pass (owner batch approval) |
| 9 | Offline gating: muted grey (not red), inert; tabs still navigate | ✅ pass (owner batch approval) |
| 10 | Overall feel: IME raise/lower smooth, swipes instant | ✅ pass (owner batch approval) |

**Gate result: APPROVED** (build under test: GitHub prerelease `v1.3.0-rc1`, APK + server exe, 2026-07-17)
