# Phase 11: Browser bookmarks — view, open, star current tab - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-29
**Phase:** 11-browser-bookmarks-view-open-star-current-tab
**Areas discussed:** Where bookmarks live, List shape & scale, Star behavior, Delete / manage scope

---

## Where bookmarks live

### Q1 — Where should the bookmark list live?

| Option | Description | Selected |
|--------|-------------|----------|
| Segmented on Browser screen | Tabs \| Bookmarks control at the top of the existing tab section; same region swaps between lists, macro grid stays below. No new tile, no navigation. | ✓ |
| Own hub tile + screen | New "Bookmarks" hub tile opening a dedicated screen. Browser screen untouched, full height for folders — but a 10th tile and one extra tap from the tabs. | |
| Stacked section below tabs | Third collapsible section: tabs, bookmarks, then macros. Both visible at once, but three scroll regions and the macro grid gets pushed far down. | |

**User's choice:** Segmented on Browser screen

### Q2 — When should the phone pull the bookmark snapshot?

| Option | Description | Selected |
|--------|-------------|----------|
| Lazy — on first Bookmarks tap | Screen opens on Tabs and primes tabs only; bookmarks requested on first segment switch, then kept live by push. Brief empty state on that first switch. | ✓ |
| Eager — both on screen open | Segment switching is instant, at the cost of an extra request + large frame on every Browser open even when unused. | |
| You decide | Let the planner pick from measured snapshot size. | |

**User's choice:** Lazy — on first Bookmarks tap

### Q3 — On the Bookmarks segment, what happens to the 7-button macro grid?

| Option | Description | Selected |
|--------|-------------|----------|
| Stays visible (same as Tabs) | Segment swaps only the list region; macros pinned below in both. Consistent layout, no jumping chrome. | ✓ |
| Hidden — bookmarks take full height | Bookmarks get the whole screen; macros disappear and the layout shifts on every switch. | |
| You decide | Let the UI spec settle it. | |

**User's choice:** Stays visible (same as Tabs)

**Notes:** Placement resolved in three questions; user selected "Next area" without further digging. Segment persistence across app restarts, empty-state copy, and a count badge were offered as further topics and left to Claude's discretion.

---

## List shape & scale

### Q1 — What does the bookmark list actually show?

| Option | Description | Selected |
|--------|-------------|----------|
| Folder drill-down | Start at top level; folder rows drill in, back goes up. Handles any collection size; each level fits the frame budget. Needs breadcrumb/back UI. | ✓ |
| Flat list, capped | One flattened list, folder structure discarded, capped like the 50-tab cap. Simplest wire and UI, but past the cap bookmarks are silently invisible. | |
| Bookmarks bar only | Just the pinned quick-access items. Smallest payload and UI; anything filed deeper is unreachable. | |

**User's choice:** Folder drill-down

### Q2 — How does the tree get to the phone — one snapshot, or per-folder fetch?

| Option | Description | Selected |
|--------|-------------|----------|
| Whole tree, one snapshot | Full node list pushed once and re-pushed on change; phone navigates locally with zero latency and no request-correlation on the push-only ext leg. Needs a node cap + truncation story. | ✓ |
| Per-folder fetch | One folder at a time via a relayed request/reply. Scales to any size, tiny frames — but adds request/reply to a push-only leg and a loading state per folder tap. | |
| You decide | Measure a real bookmark export against the 56 KB budget first. | |

**User's choice:** Whole tree, one snapshot

### Q3 — Do bookmark rows carry favicons like tab rows do?

| Option | Description | Selected |
|--------|-------------|----------|
| No icons — glyphs only | Folder glyph + generic bookmark glyph. Keeps nodes to id + title + parent so a whole-tree snapshot fits comfortably. Plainer than tab rows. | ✓ |
| Favicons, stripped when over budget | Visual parity with tab rows via the existing _favicon fetch, but up to 4096 chars each would blow 56 KB fast — which rows keep an icon becomes unpredictable. | |
| You decide | Let the UI spec and measured sizes settle it. | |

**User's choice:** No icons — glyphs only

### Q4 — What sits at the top level of the drill-down?

| Option | Description | Selected |
|--------|-------------|----------|
| All roots as folders | Bookmarks bar, Other bookmarks, Mobile bookmarks each drillable. Nothing unreachable; one extra tap to the bar items. | ✓ |
| Bookmarks bar contents, roots reachable | Opens directly on the bar's children (zero extra taps) with the other roots mixed into that same level. | |
| You decide | Let the UI spec pick once the real tree shape is known. | |

**User's choice:** All roots as folders

**Notes:** Node-cap truncation behaviour, folder child counts, empty-folder copy, and in-folder sort order were offered as follow-ups and left to Claude's discretion.

---

## Star behavior

### Q1 — Which tabs get a star control?

| Option | Description | Selected |
|--------|-------------|----------|
| Every tab row (trailing button) | Trailing star per row, filled when already bookmarked. Star anything visible without switching to it. Narrows the tappable title area. | ✓ |
| Active tab only | One control outside the list acting on the active tab — the literal phase scope; rows untouched, but bookmarking another tab means activating it first. | |
| You decide | Let the UI spec pick after measuring the row against group-block containment. | |

**User's choice:** Every tab row (trailing button)

### Q2 — Where does starring a tab file the new bookmark?

| Option | Description | Selected |
|--------|-------------|----------|
| Bookmarks bar root | Matches Chrome's own star; id resolved via getTree(), never hardcoded "1". No picker, no carried state. | ✓ |
| Currently open folder | Files into whichever folder the Bookmarks segment shows, falling back to the bar. Convenient but the destination depends on invisible state from the other segment. | |
| Other bookmarks | Keeps phone-made bookmarks out of the curated bar, at the cost of a drill-down to find them. | |

**User's choice:** Bookmarks bar root

### Q3 — What does tapping a filled star do?

| Option | Description | Selected |
|--------|-------------|----------|
| Bar-only star — safe by construction | Star reflects/acts on the bar copy only; can never delete a bookmark filed in a folder. But a folder-filed URL shows an empty star, and starring adds a second copy. | |
| Anywhere star — removes all copies | Always-truthful star matching Chrome's reading, but one tap can silently delete a deliberately filed bookmark with no undo. | |
| Anywhere star — confirm to remove | Truthful star; removal asks for confirmation naming what will be deleted. Protects curated bookmarks at the cost of a dialog and a confirm surface. | ✓ |

**User's choice:** Anywhere star — confirm to remove

### Q4 — After tapping star, when does the icon actually fill?

| Option | Description | Selected |
|--------|-------------|----------|
| Optimistic — fills instantly | Flips on tap, reconciles against the next snapshot. Feels instant; adds local optimistic state (the pattern Media's mute deliberately avoided). | ✓ |
| Wait for the push | Pure follow-the-server, no local state — but a visible delay of roughly the debounce interval before the tap looks like it did anything. | |
| You decide | Let the planner measure the real round-trip. | |

**User's choice:** Optimistic — fills instantly

**Notes:** The trailing-button constraint came from the shipped implementation (tap-down, long-press and swipe are all already spent on tab rows), not from preference. Confirm-surface shape, haptics/toast, and unauthed star rendering left to Claude's discretion.

---

## Delete / manage scope

### Q1 — Can the user delete a bookmark from inside the Bookmarks list itself?

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — same confirm gate as unstar | One deletion path, one safety story; makes the list a real manager. Needs a delete affordance and a folder rule. | ✓ |
| No — view and open only in v1 | Smallest surface and risk; cleaning up bookmarks stays a PC job. | |
| Links only, never folders | Keeps most of the manager value while making a subtree wipe structurally impossible. | |

**User's choice:** Yes — same confirm gate as unstar

### Q2 — Does delete apply to folder rows too, and how is that guarded?

| Option | Description | Selected |
|--------|-------------|----------|
| Folders deletable, confirm names the count | Full parity with the PC, but the single most destructive action in the app with no undo. | |
| Links only — folders have no delete | Subtree loss structurally impossible; folder deletion stays a PC job where undo exists. | |
| Folders deletable only when empty | Cleanup possible with zero subtree-wipe risk; folders must be emptied row by row first. | ✓ |

**User's choice:** Folders deletable only when empty

### Q3 — After opening a bookmark in a new PC tab, what does the phone do?

| Option | Description | Selected |
|--------|-------------|----------|
| Switch to the Tabs segment | Phone follows the PC; the new tab is immediately there to close or star — but you lose your place in the folder. | |
| Stay in Bookmarks | Open several in a row without re-navigating; no on-screen confirmation beyond a haptic tick. | ✓ |
| You decide | Let the UI spec pick. | |

**User's choice:** Stay in Bookmarks

**Notes:** User selected "I'm ready for context" at the final gate — no additional gray areas explored. Rename / move / reorder / create-folder confirmed as deferred.

---

## Claude's Discretion

- Exact `bm.*` message names, payload shapes, and node element shape (the roadmap's flattened-node-list + per-`TabEl` `bookmarked` flag sketch is a starting point, not locked).
- Node cap value and the truncation UI story.
- Whether the chosen segment persists across screen opens / app restarts.
- Segment control styling, empty-folder copy, folder child counts, in-folder sort order, breadcrumb vs plain back affordance.
- The delete gesture on a bookmark row and the confirm surface's shape (dialog / sheet / slide-to-confirm).
- Haptics and toasts on star, open, and delete.
- Whether the extension-not-connected install hint is shared across both segments.

## Deferred Ideas

- Rename / move / reorder bookmarks, and create-folder.
- Bookmark search / filter.
- Non-empty folder deletion (would need an undo story first).
- Per-folder lazy fetch on the ext leg (revisit only if a real tree overruns 56 KB).
- Favicons on bookmark rows (payload budget; unlocked only by per-folder fetch).
- Reusing an already-open tab instead of always opening a new one.
