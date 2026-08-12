# Remote Control

## What This Is

An Android app that turns a phone into a wireless mouse, keyboard, and control center for a Windows laptop, paired with a lightweight Windows tray server. It replaces the Remote Mouse app for the owner: every feature free, with a modern dark-minimal UI instead of a dated, paywalled one.

Shipped as v1.0 on 2026-08-12 and in daily personal use. All three components — app, server and browser extension — check for and install their own updates from a public release mirror.

## Current State

**Shipped: v1.0 MVP** (12 phases, 108 plans, 673 commits, 2026-07-07 → 2026-08-12), released as `v1.6.3`.

The product does what it set out to do: the owner replaced the paid app with it. Distribution is a sideloaded APK plus an Inno Setup PC installer, both published with SHA-256 digests on `nandodeomkar/remote-control-releases`, and the in-app updater keeps all three pieces current.

Currently on a **dogfood/refine hold** — no new milestone planned. See `.planning/MILESTONES.md` for the full v1.0 record and `.planning/STATE.md` `## Deferred Items` for the ten items acknowledged at close.

## Core Value

Phone controls the laptop over WiFi with zero friction: instant cursor response, full keyboard, and the control-center extras (media, power, apps, clipboard, presenter, browser) — all free.

**Still correct after shipping.** Daily use confirmed the priority order: cursor latency is the thing that would have killed it, and it was retired first (p50 6ms). The one thing real use changed is *access* — the owner wants the trackpad and keyboard reachable from every screen rather than being destinations, which is what the summon-bar proposal is about.

## Requirements

### Validated

- ✓ Trackpad: cursor move, left/middle/right click, tap-to-click, two-finger scroll, drag — Phase 4 (pinch zoom added later, protoVersion 1.7)
- ✓ Keyboard: free text typing, F1–F12, numpad, arrows/nav cluster, sticky modifiers for combos — Phase 4, rebuilt as four full-screen swipeable pads in Phase 10
- ✓ LAN auto-discovery + one-time PIN pairing, remembered devices reconnect silently — Phase 3 (QR pairing added later; CONN-04's IP-change half fixed 2026-08-11)
- ✓ Media controls: play/pause, next/prev, absolute volume slider, mute — Phase 5
- ✓ Power controls: lock, sleep, restart, shutdown behind slide-to-confirm — Phase 5
- ✓ Presentation remote: next/prev, start/end show, blank screen, elapsed timer — Phase 5 (PowerPoint desktop; web Google Slides a known limitation)
- ✓ Browser controls: back/forward, new/close tab, refresh, zoom — Phase 5, extended to live tab list + groups + bookmarks via a Chrome extension relay (Phase 11)
- ✓ App launcher/switcher: running windows (focus/close), pinned favorites (launch) — Phase 6
- ✓ Cross-device clipboard: manual send/fetch both ways, optional auto-sync, last-5 history — Phase 6
- ✓ Windows tray server: auto-start, settings window, pause input, paired-device revoke — Phase 7
- ✓ In-app updates for app, server and extension from a public mirror — Phase 12 (observed on hardware 2026-08-08)
- ✓ Windows installer — shipped as Inno Setup (quick 260729-38z), reversing the v1 "bare exe" decision

### Active

Nothing committed. The one designed-but-unplanned candidate:

- [ ] **The summon bar** — a permanent bottom bar on every screen that raises the trackpad and keyboard IN PLACE, retiring the floating bubble and `windowPositionProvider`; both hub tiles move last rather than being deleted. Designed 2026-08-11 from several days of real use, routed to v1.1, ~4-6 plans. Full design and its five landmines: `.planning/notes/summon-bar-trackpad-keyboard.md`.

### Out of Scope

- Bluetooth / USB transport — WiFi LAN covers the use case; two codepaths not worth it. **Reason held up**: no situation in daily use wanted it.
- iOS app, Linux/macOS servers — the protocol-first architecture supports them; deferred until Android+Windows is proven. **Still deferred, and the architecture did hold**: `server-core` compiles with zero Windows dependencies.
- Play Store release, crash reporting, privacy policy — personal use. **Partially moved**: releases are now cut to a PUBLIC mirror repo so the updater can fetch anonymously, but the app itself is still sideloaded and unlisted.
- Gyro/air mouse, file transfer, home-screen widgets — not needed by the owner; add-later candidates.
- Internet/remote access (WAN) — LAN-only by security design; never internet-exposed.
- Voice control, macros/scripting, Wake-on-LAN, multi-monitor spanning controls — no demand in v1 use.

## Context

- Replaced Remote Mouse (Play Store) for the owner's daily use. That goal is met.
- Approved design spec: `docs/superpowers/specs/2026-07-07-remote-control-design.md`. A second approved spec covers in-app updates: `docs/superpowers/specs/2026-08-01-in-app-updates-design.md`.
- Monorepo: `protocol/` (spec + fixtures), `server/` (Rust workspace), `app/` (Flutter), `extension/` (Chrome), `installer/`, `tools/release.ps1`.
- Codebase at v1.0: ~22.6k lines of Rust, ~44.1k lines of Dart. 872 Flutter tests, 312 Rust workspace tests, 22 Dart protocol tests.
- Releases are cut by `tools/release.ps1`, which bumps all three versions, builds all three artifacts and publishes them with digests. `gh.exe` lives at `C:\Program Files\GitHub CLI\gh.exe` and is not on PATH.
- Known technical debt at close: 4 phases without a `VERIFICATION.md`, Nyquist validation at 0/12, and no automated gate on keymap cross-language lockstep. See STATE.md `## Deferred Items`.

## Constraints

- **Tech stack**: Flutter (Android-first) client, Rust server (tokio + tungstenite, enigo, tray-icon) — locked by spec for future iOS/Linux/macOS expansion
- **Transport**: WebSocket only (JSON + 9-byte binary mouse frames), UDP broadcast discovery — locked by spec; transport abstracted so a UDP input channel can be added later. **The UDP reconsideration trigger was never pulled** — phase 2's gate passed at ~3× margin.
- **Security**: PIN pairing (6-digit, 60s expiry, lockout), SHA-256-hashed tokens, LAN-only binding, power actions double-confirmed — locked by spec
- **Performance**: cursor response visually instant on same LAN (<30ms end-to-end) — measured p50 6ms / p95 10ms
- **UI**: dark minimal theme (#0E0F12, blue accent), dashboard home. **Amended**: the "persistent trackpad quick-bar" in the original mockup lock was deleted outright in Phase 8 (D8-06) and replaced by a draggable bubble + floating trackpad window. The summon-bar proposal would replace that in turn.
- **Two-sided version coupling**: the keymap vocabulary and binary opcodes grew during v1, so a release must ship the server exe alongside the APK. An old server does not break the session — unknown opcodes are dropped per SPEC §9 — but the affected feature silently does nothing.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| WiFi LAN only | Control-center features need a PC server anyway; BT/USB add codepaths without value | ✓ Good — nothing in daily use wanted another transport |
| Flutter + Rust | One client codebase to iOS later; one server core to Linux/macOS via enigo | ✓ Good — `server-core` still has zero Windows deps and compiles on CI Linux |
| WebSocket-only transport | LAN RTT sufficient; simplest portable protocol; UDP bolt-on possible later | ✓ Good — p50 6ms / p95 10ms; the UDP reconsideration was never triggered |
| Auto-discover + PIN pairing | Zero-config UX with real auth; safer than LAN-trust | ✓ Good — one real gap (CONN-04's beacon binding was screen-scoped), found by audit and fixed |
| Dashboard home + trackpad quick-bar | User preference from mockups; control-center identity with fast mouse access | ⚠️ Revisit — the dashboard held, the quick-bar did not. Deleted in Phase 8 for a bubble; the bubble is now itself proposed for replacement by the summon bar |
| Dark minimal visual style | User preference from mockups; OLED-friendly, pro-tool feel | ✓ Good — survived a full prototype-matching pass in Phase 9 with zero palette changes |
| Personal use before public | Ship fast for owner; store compliance/installer deferred | ⚠️ Partly reversed — an installer shipped anyway, and releases now go to a public mirror so the updater can fetch without a token |
| Protocol-first, fixture-locked, two-language | Both codecs pinned to the same golden fixtures | ✓ Good — the strongest decision of the milestone; no cross-language wire bug reached hardware |
| Test the seam, inject the boundary | Keeps sequencing testable without real processes | ⚠️ Revisit — it is also how the v1.0 blocking defect hid: `spawn_helper` was the one function in the update path no test ever executed |

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
*Last updated: 2026-08-12 after the v1.0 milestone*
