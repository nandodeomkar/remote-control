# Remote Control

## What This Is

An Android app that turns a phone into a wireless mouse, keyboard, and control center for a Windows laptop, paired with a lightweight Windows tray server. It replaces the Remote Mouse app for the owner: every feature free, with a modern dark-minimal UI instead of a dated, paywalled one.

## Core Value

Phone controls the laptop over WiFi with zero friction: instant cursor response, full keyboard, and the control-center extras (media, power, apps, clipboard, presenter, browser) — all free.

## Requirements

### Validated

- ✓ Trackpad: cursor move, left/middle/right click, tap-to-click, two-finger scroll, drag — Phase 4
- ✓ Keyboard: free text typing, F1–F12, numpad, arrows/nav cluster, sticky modifiers for combos — Phase 4
- ✓ LAN auto-discovery + one-time PIN pairing, remembered devices reconnect silently — Phase 3
- ✓ Media controls: play/pause, next/prev, absolute volume slider, mute — Phase 5 (on-device UAT 6/6, security pass)
- ✓ Power controls: lock, sleep, restart, shutdown behind slide-to-confirm — Phase 5
- ✓ Presentation remote: next/prev, start/end show, blank screen, elapsed timer — Phase 5 (PowerPoint desktop; web Google Slides out of scope — known limitation)
- ✓ Browser controls: back/forward, new/close tab, refresh, zoom (key macros) — Phase 5

### Active

- [ ] App launcher/switcher: running windows (focus/close), pinned favorites (launch)
- [ ] Cross-device clipboard: manual send/fetch both ways, optional auto-sync, last-5 history
- [ ] Windows tray server: auto-start, settings window, pause input, paired-device revoke

### Out of Scope

- Bluetooth / USB transport — WiFi LAN covers the use case; two codepaths not worth it for v1
- iOS app, Linux/macOS servers — architecture (protocol-first) supports them; deferred until Android+Windows proven
- Installer (MSI) — v1 ships bare exe for personal use; installer when going public
- Play Store release, crash reporting, privacy policy — personal use until owner deems it public-ready
- Gyro/air mouse, file transfer, home-screen widgets — not needed by owner, add-later candidates

## Context

- Owner currently uses Remote Mouse (Play Store); it has all needed features but paywalls most and looks dated. This project replaces it for daily personal use.
- Approved design spec: `docs/superpowers/specs/2026-07-07-remote-control-design.md` — architecture, wire protocol, screens, error handling, and testing already decided and committed. Planning must follow it.
- Greenfield monorepo: `protocol/` (spec + fixtures), `server/` (Rust workspace), `app/` (Flutter).
- Personal use first: sideloaded APK + bare exe. Public release is a later milestone gate.

## Constraints

- **Tech stack**: Flutter (Android-first) client, Rust server (tokio + tungstenite, enigo, tray-icon) — locked by spec for future iOS/Linux/macOS expansion
- **Transport**: WebSocket only (JSON + 9-byte binary mouse frames), UDP broadcast discovery — locked by spec; transport abstracted so UDP input channel can be added later
- **Security**: PIN pairing (6-digit, 60s expiry, lockout), SHA-256-hashed tokens, LAN-only binding, power actions double-confirmed — locked by spec
- **Performance**: cursor response visually instant on same LAN (<30ms end-to-end)
- **UI**: dark minimal theme (#0E0F12, blue accent), dashboard home + persistent trackpad quick-bar — locked by mockup selections

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| WiFi LAN only | Control-center features need a PC server anyway; BT/USB add codepaths without value | — Pending |
| Flutter + Rust | One client codebase to iOS later; one server core to Linux/macOS via enigo | — Pending |
| WebSocket-only transport | LAN RTT sufficient; simplest portable protocol; UDP bolt-on possible later | — Pending |
| Auto-discover + PIN pairing | Zero-config UX with real auth; safer than LAN-trust | — Pending |
| Dashboard home + trackpad quick-bar | User preference from mockups; control-center identity with fast mouse access | — Pending |
| Dark minimal visual style | User preference from mockups; OLED-friendly, pro-tool feel | — Pending |
| Personal use before public | Ship fast for owner; store compliance/installer deferred | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-11 after Phase 5*
