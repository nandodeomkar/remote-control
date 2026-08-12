# Phase 7: Server Shell, Dashboard & Polish - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-12
**Phase:** 7-Server Shell, Dashboard & Polish
**Areas discussed:** Todo fold, Trackpad quick-bar, Home identity, Settings entry, Accent, Pairing lifecycle, UIPI surfacing, Firewall warning

---

## Folded Todos

| Todo | Description | Folded |
|------|-------------|--------|
| One-pairing-per-run | Server pairs only one device per run (in-memory tokens). Fold = persist token hashes + on-demand pairing so a 2nd phone / re-pair works without a restart. Enables SRV-03 revoke. | ✓ |
| noPairing copy split | authFail{noPairing} covers two cases (revoked token vs no PIN window); phone shows misleading copy. Fold = distinct reason (noPinWindow) + correct copy. | |

**User's choice:** Fold one-pairing-per-run only.
**Notes:** noPairing copy split left out; recorded as a reviewed-not-folded deferred todo. Flagged that it shares the pairing code path being reworked, so the planner may close it opportunistically.

---

## Trackpad quick-bar (UI-01)

| Option | Description | Selected |
|--------|-------------|----------|
| Trackpad button | One affordance; tap pushes the full Trackpad screen. Faithful to "a trackpad shortcut", least work. | ✓ |
| Button + L/R click | Trackpad button plus quick left/right click buttons — one-handed nudge from anywhere. | |
| Slide-up peek pad | Bar expands into a live mini-trackpad overlay usable without leaving the screen. Richest, most work. | |

**User's choice:** Trackpad button (Recommended).
**Notes:** Live peek pad recorded as a deferred UX idea.

---

## Home identity

| Option | Description | Selected |
|--------|-------------|----------|
| Dashboard is home | Dashboard (8 tiles) always home with an offline state; device-list becomes the add/switch-PC screen. Matches spec offline-dashboard. | ✓ |
| Device-list stays home | Keep current structure; dashboard opens after connecting. Less rework, diverges from spec. | |

**User's choice:** Dashboard is home (Recommended).
**Notes:** Reroute lands in main.dart (device-list is home today).

---

## Settings entry

| Option | Description | Selected |
|--------|-------------|----------|
| App-bar gear icon | Gear in the dashboard app bar; keeps the 8-tile grid intact and reachable when offline. | ✓ |
| 9th tile in the grid | Settings becomes a tile; breaks the locked 2×4 = 8-tool grid. | |
| In the quick-bar | Settings entry in the persistent bottom bar. | |

**User's choice:** App-bar gear icon (Recommended).

---

## Accent color

| Option | Description | Selected |
|--------|-------------|----------|
| Fixed blue #4C8DFF | Single locked accent; consolidate the duplicated per-file palette const into one shared theme. | ✓ |
| User-selectable presets | A few preset accents in Settings (spec-listed); requires threading an accent provider through every screen. | |

**User's choice:** Fixed blue #4C8DFF (Recommended).
**Notes:** Accent presets deferred.

---

## Pairing lifecycle & multi-device (SRV-03)

| Option | Description | Selected |
|--------|-------------|----------|
| On-demand + smart startup | "Pair new device" in tray + settings opens a PIN on demand; auto-open PIN at startup only when zero devices paired; revoke drops the live session immediately. | ✓ |
| Always auto-PIN at startup | Server always opens a PIN on launch (today's behavior); PIN toast every boot. | |
| Settings-window only | Pair a new device only via settings (no tray shortcut). | |

**User's choice:** On-demand + smart startup (Recommended).
**Notes:** Token hashes persist in %APPDATA%/RemoteControl/config.toml.

---

## UIPI surfacing (SRV-05)

| Option | Description | Selected |
|--------|-------------|----------|
| Transient banner | Non-blocking banner when a blocked input is attempted ("running as administrator"), auto-dismisses. | ✓ |
| Persistent header chip | Status stays while an elevated window is foreground; needs continuous elevation tracking. | |
| Per-action toast | A toast each dropped input; can spam. | |

**User's choice:** Transient banner (Recommended).
**Notes:** Detection mechanism + status-message shape → researcher.

---

## Firewall warning (SRV-04)

| Option | Description | Selected |
|--------|-------------|----------|
| Tray state + notification | Tray warning state + a Windows notification with a fix hint at startup; persistent hint in settings. | ✓ |
| Tray-only, quiet | Only the tray icon/tooltip changes; no startup notification. | |

**User's choice:** Tray state + notification (Recommended).

---

## Claude's Discretion

- Settings-window toolkit (eframe/egui on the winit loop) + layout.
- Tray icon asset, pause-input visual feedback, Explorer-restart survival.
- Autostart mechanism (auto-launch / HKCU Run key) + toggle wiring.
- config.toml schema.
- Port-change-live-rebind vs restart-required (research flag).
- Quick-bar height/placement + hide-on-trackpad mechanic.
- Theme file structure and token replacement.
- Scroll-direction plumbing into the trackpad driver.
- Proper AUMID registration for tray/notification identity.

## Deferred Ideas

- User-selectable accent presets (chose fixed blue).
- Live "peek" trackpad overlay on tool screens (chose nav button).
- noPairing copy split todo (reviewed, not folded — may close opportunistically with the pairing rework).
