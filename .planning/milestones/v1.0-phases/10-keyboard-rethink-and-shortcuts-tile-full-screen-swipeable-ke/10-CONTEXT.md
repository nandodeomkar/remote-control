# Phase 10: Keyboard rethink + Shortcuts tile - Context

**Gathered:** 2026-07-16
**Status:** Ready for planning
**Source:** Owner discussion in-session (chat = discuss-phase; decisions below are user-locked)

<domain>
## Phase Boundary

Two deliverables, both keyboard-domain:

1. **Keyboard screen redesign** — replace the bottom-docked panel + tiny Nav/Fn/Num switcher with full-screen swipeable pads. The mouse/trackpad is untouched ("mouse works flawlessly" — owner). Typing still rides the system IME; this phase fixes the *extras* UX.
2. **Shortcuts hub tile** — a new tile on the hub: one-tap Windows shortcut buttons (labeled by effect, e.g. "Show desktop") that fire the existing `key {action: tap, mods}` combo path.

Out of scope: trackpad screen's docked KeyboardPanel (D-07) stays as-is unless a shared component forces a mechanical touch-up; no protocol version bump; no server executor changes beyond keymap vocabulary.

</domain>

<decisions>
## Implementation Decisions

### Keyboard screen — full-screen pads (user-locked)
- Keep system IME for typing. `HiddenTextInput` + `ImeDiffProducer` diff path unchanged.
- Keyboard screen becomes swipeable full-screen pads with bottom tabs: **Type | Arrows | Numpad | Fn** (PageView + tab bar replaces the Nav/Fn/Num switcher).
- **Modifier chips persistent across all pads** (one `ModifierFsm`, chips row stays visible on every page) — Ctrl+F5, Ctrl+arrow, combos work from any pad.
- **Type page**: system IME raised + one slim row of high-frequency keys (Esc, Tab, arrows, Del). Only page where the IME shows; switching to other pads lowers it.
- **Arrows page**: IME down. Large inverted-T arrows + Home/End/PgUp/PgDn around it. Hold-to-repeat retained (existing D-11 server-side autorepeat via down/up).
- **Numpad page**: IME down. Full-screen calculator-style grid, big Enter (existing Num codes).
- **Fn page**: F1–F12 grid, large caps; include Esc on this pad too.
- Key sizes must be dramatically larger than current panel (whole point of redesign — current keys cramped in ~200px strip).

### Shortcuts tile (user-locked)
- New hub tile "Shortcuts". Screen = scrollable grouped sections, big buttons labeled by **effect** ("Show desktop"), combo shown as small subtext ("Win+D") for learning.
- Buttons fire one `key {action: tap, mods: [...]}` message, haptic tick on press, gated muted-not-red when unauthed (house pattern).
- Catalog (user-approved):
  - **Windows/Desktop**: Show desktop (Win+D), Task view (Win+Tab), Snap left (Win+Left), Snap right (Win+Right), File Explorer (Win+E), Settings (Win+I), Task Manager (Ctrl+Shift+Esc).
  - **Screenshot**: Snip tool (Win+Shift+S), Full screenshot to file (Win+PrintScreen), Screenshot to clipboard (PrintScreen).
  - **Browser/App**: Refresh (F5), Hard refresh (Ctrl+Shift+R), New tab (Ctrl+T), Close tab (Ctrl+W), Reopen tab (Ctrl+Shift+T), Find (Ctrl+F), Zoom in (Ctrl+Plus), Zoom out (Ctrl+Minus), Zoom reset (Ctrl+0).
  - **Editing**: Copy, Cut, Paste, Undo, Redo, Select all (Ctrl+C/X/V/Z/Y/A).
- **User-excluded**: Alt+Tab (Apps remote covers app switching), Win+L lock (not wanted), Ctrl+Alt+Del (SendInput cannot inject the secure attention sequence).

### Wire/keymap (user-locked approach)
- **No protocol change.** Reuse existing `key` message tap+mods path.
- Extend `server/server-windows/src/executors/keymap.rs` `CLIENT_KEY_CODES` AND the Dart mirror `kClientKeyCodes` (app/remote_control/lib/keyboard/key_rows.dart) with every code the catalog needs: letters used by shortcuts (C, X, V, Z, Y, A, D, E, I, F, T, W, R, S), `PrintScreen`, `Plus`/`Minus`/`0` equivalents for zoom, etc. keymap.rs stays SINGLE SOURCE OF TRUTH; both coverage tests updated (Rust `keymap_covers_all_codes`, Dart widget/vocabulary test).

### Claude's Discretion
- Exact pad layouts, key dimensions, tab icons/labels, page order and default page.
- Whether last-open pad persists (existing `keyboard.rowGroup` pref may be repurposed or replaced).
- Shortcut button icon choices (material_symbols_icons), section ordering, grid columns.
- How Zoom +/- codes are named on the wire (e.g. `Plus`/`Minus` vs `Equal`/`Minus` — pick what maps cleanly to Windows VKs in enigo).
- Whether Shortcuts screen reuses a generic "big action button" widget shared with pads.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Keyboard client (all under app/remote_control/lib/keyboard/)
- `keyboard_screen.dart` — current screen being replaced (panel mounted expanded)
- `keyboard_panel.dart` — panel: ModifierFsm wiring, D-12 disconnect reset, held-key flush (CR-01/CR-02 invariants MUST survive the redesign)
- `key_rows.dart` — `kClientKeyCodes` Dart mirror, `KeyCapDef`, cap emission model (D-11 down/up + deferred tap+mods), group switcher being replaced
- `hidden_text_input.dart`, `diff_ops.dart` — IME path (unchanged)
- `modifier_fsm.dart`, `modifier_chip.dart` — chips (kept, made persistent across pads)

### Server
- `server/server-windows/src/executors/keymap.rs` — `CLIENT_KEY_CODES` single source of truth + `keymap_covers_all_codes` gate

### Hub / house patterns
- `app/remote_control/lib/hub/hub_screen.dart` — tile grid, `_open` BubbleScaffold wrap (new Shortcuts tile follows this)
- `app/remote_control/lib/media/media_screen.dart` — reference for a gated action-button tool screen
- `app/remote_control/lib/theme/tokens.dart` — 7 locked D-12 tokens; palette guard test forbids new colors there

</canonical_refs>

<specifics>
## Specific Ideas

- Owner's core complaint: "current version is very messy and hard to use" — keys too small, one strip serving four jobs. Success = each pad feels like a dedicated remote.
- Buttons labeled by effect, not by chord — chord as caption (learning aid).
- Existing stuck-key invariants are sacred: cap dispose mid-hold releases, disconnect wipes held set without stale ups, always-wired release handlers (IN-04). Any new cap/pad widget must preserve them.

</specifics>

<deferred>
## Deferred Ideas

- Favorites row / user-customizable shortcut catalog — v-next.
- Alt+Tab hold-to-cycle interaction — Apps remote covers switching for now.
- Custom in-app QWERTY — never (system IME is better, spec agrees).

</deferred>

---

*Phase: 10-keyboard-rethink-and-shortcuts-tile*
*Context gathered: 2026-07-16 via in-session owner discussion*
