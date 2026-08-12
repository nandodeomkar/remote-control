---
phase: 10-keyboard-rethink-and-shortcuts-tile
plan: 06
status: complete
completed: 2026-07-17
requirements: [KEY-01, KEY-02, KEY-03, KEY-04]
---

# 10-06 Summary — On-device UAT gate

## Outcome

**Gate APPROVED.** Phase 10's keyboard redesign and Shortcuts tile passed the on-device UAT
gate on the owner's Xiaomi 25080RABDI against a Windows 11 PC.

## Task 1 — Regression + fresh release build

All three suites green, recorded in `10-UAT.md`:

- `flutter analyze` — clean (44.2s)
- `flutter test` — 539 passed, 0 failed
- `cargo test -p server-windows` — 38 passed, 0 failed, 2 ignored

Fresh-APK guard (T-10-08) held: `flutter build apk --release` ran fresh this session
(2026-07-17 09:20 IST, Gradle `assembleRelease` 88.5s). The server exe was also rebuilt fresh
(09:19 IST) because the 10-01 vocabulary extension is two-sided — an old server would silently
drop the 18 new key codes and the Shortcuts tile would no-op.

## Task 2 — Human walkthrough

**Deviation (Rule 3, distribution only):** instead of `flutter install` over USB, both fresh
artifacts were published to GitHub prerelease `v1.3.0-rc1`
(`RemoteControl-v1.3.0-rc1.apk`, `RemoteControl-Server-v1.3.0-rc1.exe`) at the owner's request
and installed from there. Same freshly-built artifacts; the fresh-build precondition holds and
the release doubles as the distributable.

Owner verdict: "works, its not perfect but it works" → asked to name gaps against the 10-point
checklist → **"pass"** (batch approval, no itemized defects). All 10 checks recorded as pass in
`10-UAT.md`. The unnamed "not perfect" impression is explicitly NOT a scoped gap — future
irritations go to the backlog, not back into this phase.

## Phase-level notes

- Phase 10 is complete: all 6 plans have summaries, all waves closed.
- v1.3.0-rc1 is promotable to a stable v1.3.0 release (assets already built and field-tested);
  version fields in pubspec/Cargo.toml were deliberately left untouched, consistent with prior
  tag-only release practice.
- No gap-closure plans created.
