# Quick Task 260716-oi2: Browser tab list + switching via Chrome extension - Context

**Gathered:** 2026-07-16
**Status:** Ready for planning

<domain>
## Task Boundary

On the app's browser remote screen, show the tabs open in the PC's browser and let the user switch to (or close) a tab by tapping it. Tab data comes from a new Chrome/Edge browser extension that talks to the existing Rust server; the server relays tab state to the phone over the existing WebSocket protocol.

</domain>

<decisions>
## Implementation Decisions

### Tab source (locked earlier)
- Browser extension (MV3, Chromium) — NOT UI Automation. User explicitly chose reliability + favicons over zero-install.

### Distribution
- Unpacked extension folder zipped into the GitHub release; friends load via chrome://extensions → Developer mode → Load unpacked. README gets a walkthrough section. No Web Store.

### Tab display
- Title + favicon per tab (favicon as small data URL from the extension). Active tab visually marked.

### Actions
- Tap = switch to tab. Swipe or long-press = close tab. No new-tab from the list (existing `newtab` macro already covers it).

### Fallback when extension not connected
- Browser screen keeps ALL existing key-macro controls working, and the tab section shows an "Install the browser extension" hint (linking to the README section) instead of a list.

### Claude's Discretion
- Extension↔server transport (dedicated localhost WS endpoint vs existing port with a distinct role) — pick what fits the existing tokio/tungstenite architecture; localhost-only binding for the extension side is a hard security requirement.
- Protocol message naming/shape, favicon size cap, tab-list debounce/refresh strategy.
- UI layout of the tab list within the existing dark-minimal browser screen.

</decisions>

<specifics>
## Specific Ideas

- Existing `browser` C→S macro message stays untouched (back/forward/newtab/closetab/refresh/zoom) — the tab list is additive.
- Server pause semantics: tab-switch/close commands from the phone are executor-bound and must respect pause (drop while paused), same as the `browser` macro today (SPEC line ~177).
- Extension is a new top-level artifact directory (e.g. `extension/`) in the monorepo with its own README.
- Protocol changes go through `protocol/SPEC.md` + fixtures + both codecs (Rust `server-core`, Dart `remote_protocol`) per the repo's protocol-first contract testing rule.

</specifics>

<canonical_refs>
## Canonical References

- `protocol/SPEC.md` — wire contract; `browser` macro at line ~119, pause semantics ~177
- CLAUDE.md tech-stack constraints (tokio-tungstenite 0.29, riverpod 3.x, dark-minimal UI, Material Symbols Rounded only in lib/)

</canonical_refs>
