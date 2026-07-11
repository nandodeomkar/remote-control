# Phase 6: Apps & Clipboard - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-11
**Phase:** 6-Apps & Clipboard
**Areas discussed:** Pinned favorites, Clipboard auto-sync, Clipboard history, Window-list ordering & icons

---

## Pinned favorites (APPS-02)

| Option | Description | Selected |
|--------|-------------|----------|
| PC-provided pick list | Server enumerates installed apps / Start-menu shortcuts; phone picks from it | |
| Manual path entry | User types/pastes an exe path per favorite | |
| Pin from running windows | Long-press a running window → pin; relaunch via its resolved exe path | ✓ |
| You decide | Claude picks during planning | |

**User's choice:** Pin from running windows
**Notes:** Favorites emerge from actual usage; no separate picker or manual paths. Stored client-side. Research flag: window-handle → exe-path resolution; UWP/packaged apps relaunch differently.

---

## Clipboard auto-sync (CLIP-03)

| Option | Description | Selected |
|--------|-------------|----------|
| Off by default + skip sensitive | Opt-in toggle; cap large text; best-effort skip password-manager/sensitive clips | ✓ |
| On by default, no filters | Auto-sync everything both ways | |
| Off by default, no filters | Opt-in, but no content filtering | |
| You decide | Claude picks default + filtering | |

**User's choice:** Off by default + skip sensitive
**Notes:** Safest default. Research flags: byte cap for large-clip skip; sensitive-clip detection mechanism (Windows clipboard exclusion marker).

---

## Clipboard history (CLIP-04 last-5)

| Option | Description | Selected |
|--------|-------------|----------|
| Persist + dedupe + tap→PC | Last-5 survives restart (prefs); consecutive dupes collapse; tap sets PC clipboard | ✓ |
| Session-only | History cleared on restart | |
| Persist, tap→phone | Persisted; tap copies to phone clipboard instead | |
| You decide | Claude picks persistence + reuse target | |

**User's choice:** Persist + dedupe + tap→PC
**Notes:** Reuse pushes to PC clipboard (primary value).

---

## Apps window-list ordering & icons (APPS-01)

| Option | Description | Selected |
|--------|-------------|----------|
| Z-order (Alt-Tab) + icons | Alt-Tab ordering, most-recent first, with app icons | ✓ |
| Z-order, no icons | Alt-Tab ordering, title-only | |
| Alphabetical, no icons | Sort A–Z, title-only | |
| You decide | Claude picks ordering + icons | |

**User's choice:** Z-order (Alt-Tab) + icons
**Notes:** Research flag: icon extraction + wire encoding (payload size), possible `WindowInfo` icon-field amendment.

## Claude's Discretion

- Hub tile placement/order for new Apps + Clipboard tiles (data-driven `kHubTiles`).
- Server poll cadence/debounce for `apps.changed`/`clip.changed`.
- Large-clip byte cap; sensitive-clip detection mechanism.

## Deferred Ideas

- Clipboard sync configuration UI in the settings window → Phase 7 (SRV-03).
- Todo: server one-pairing-per-run → Phase 7 (persistent tokens).
- Todo: split overloaded `noPairing` authFail copy → Phase 7 pairing work.
