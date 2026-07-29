# Phase 11: Browser bookmarks — view, open, star current tab - Context

**Gathered:** 2026-07-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Extend the shipped Tab Bridge leg so the phone can **see the PC browser's bookmarks, open one in a new tab, star/unstar a tab, and delete a bookmark**. Delivered as a second segment on the existing Browser tool screen — no new hub tile, no new screen.

Wire scope: a new phone-facing `bm.*` family (protocol minor bump **1.6** — 1.0–1.5 clients stay accepted), new ext-leg messages for the bookmark snapshot and commands, and the `bookmarks` permission added to the extension manifest.

**Out of scope:** rename, move, reorder, create-folder, bookmark search/filter, and any bookmark editing beyond create (star) and delete. No changes to the tab list's existing gestures, the 7-button macro grid, the group-block rendering, or the trackpad/keyboard paths.

</domain>

<decisions>
## Implementation Decisions

### Placement & navigation
- **D-01:** Bookmarks live behind a **Tabs | Bookmarks segmented control** at the top of the existing tab section on the Browser screen. The segment swaps only the list region — no new hub tile, no new screen, no separate route.
- **D-02:** The **7-button macro grid stays pinned below in BOTH segments.** Switching segments must not shift or hide surrounding chrome.
- **D-03:** **Lazy prime.** Screen open primes tabs only (today's `tabs.list`-on-open behavior is unchanged). The bookmark snapshot is requested the first time the user switches to the Bookmarks segment, and is kept live by push from then on.
- **D-04:** Opening a bookmark **leaves the user in the Bookmarks segment** — no auto-switch to Tabs. Several bookmarks can be opened in a row without losing the current folder position.

### List shape & wire payload
- **D-05:** **Folder drill-down navigation** — not a flat capped list, not bookmarks-bar-only.
- **D-06:** The **whole tree ships in ONE `bm.state` snapshot** pushed by the extension; the phone navigates folders **locally**. No per-folder request/reply is added to the push-only ext leg. This requires a node cap plus a defined truncation story against the 56 KB frame budget (SPEC §15).
- **D-07:** **No favicons on bookmark rows** — folder glyph for folders, generic bookmark glyph for links. This is what keeps a node small enough (id + title + parent, no URL) for the whole tree to fit one frame.
- **D-08:** The **top level lists all Chrome roots as folders** (Bookmarks bar, Other bookmarks, Mobile bookmarks) so nothing in the collection is unreachable from the phone.

### Star / unstar
- **D-09:** A **trailing star button on EVERY tab row** (not a single active-tab control). Tab rows already spend tap-down (activate), long-press and swipe (close), so a trailing button is the only free affordance.
- **D-10:** Starring files the new bookmark into the **bookmarks-bar root**, whose id is resolved via **`getTree()`** — never the hardcoded id `"1"`.
- **D-11:** **Truthful "anywhere" star:** filled = the tab's URL is bookmarked anywhere in the tree. Removing deletes **every matching-URL entry**, and is **confirm-gated** — never fire-on-tap.
- **D-12:** **Optimistic fill** — the star flips instantly on tap and reconciles against the next authoritative pushed snapshot. (Deliberately unlike the Media screen's mute, which has no optimistic flip.)

### Delete / manage scope
- **D-13:** Bookmarks **can be deleted from inside the Bookmarks list**, reusing the **same confirm gate as unstar** — one deletion path, one safety story.
- **D-14:** **Folders are deletable only when empty.** A subtree wipe from the phone is structurally impossible; emptying a folder row by row is the price. The confirm still applies.

### Preserved invariants (locked upstream — not re-decided)
- **No `url` field ever crosses the phone-facing wire** (SPEC §7). URL resolution stays extension-side: the phone sends `bm.open {id}` and the extension does `bookmarks.get(id)` → `tabs.create({url})`. The same rule binds star (extension resolves the tab's URL) and any URL-matching for the star state.
- The ext leg is **loopback-bound with no auth handshake**, and the extension always sends **full snapshots, never diffs** (the MV3 service worker is stateless by design).
- Extension-side caps are enforced **before send**; the server truncates as a belt.
- House patterns: value-equal view state, pull-on-open + push-on-change, **gated muted-not-red** when unauthed, tap-down fire + haptic tick.

### Claude's Discretion
- The exact `bm.*` message names, payload shapes, and node element shape (the roadmap's entry-scan sketch — a flattened node list with parent ids, and a per-`TabEl` `bookmarked` flag for star state — is a starting point, not a locked design).
- The node cap value and what the UI shows when the tree is truncated.
- Whether the chosen segment persists across screen opens / app restarts.
- Segment control styling, empty-folder copy, folder child counts, sort order within a folder, breadcrumb vs plain back affordance.
- The exact delete gesture on a bookmark row, and the confirm surface's shape (dialog vs sheet vs slide-to-confirm) — noting the Power screen already owns a slide-to-confirm and a red countdown dialog, and this is a much lower-stakes action.
- Haptics/toast on star, open, and delete.
- Whether the extension-not-connected install hint is shared across both segments (almost certainly yes — it is a locked fallback on the tabs side).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wire contract
- `protocol/SPEC.md` §7 — phone-facing message family registry, `TabEl`/`GroupEl` element shapes, the **no-`url`-on-the-phone-wire** rule, `err` codes. The `bm.*` family and any `TabEl` addition land here.
- `protocol/SPEC.md` §15 — extension leg: loopback bind as the auth boundary, full-snapshot-never-diff rule, single-extension policy, the 50-tab / 4096-char-icon / 16-group / 56 KB caps, and the "fixtures mandatory only for the phone-facing family" rule.
- `protocol/SPEC.md` §13 — 64 KB `max_message_size` / `max_frame_size`, enforced per-listener.
- `protocol/SPEC.md` §11 — pause semantics: executor-bound messages are dropped while paused, but reads (`tabs.list`, `apps.list`, `clip.get`) stay answered. New `bm.*` messages must be classified into one of these groups.
- `protocol/SPEC.md` §2 — versioning rule for the 1.6 minor bump (additive; 1.0–1.5 clients stay accepted).
- `protocol/fixtures/` — golden fixtures shared by the Rust and Dart codecs; per-language copies are forbidden. Note: a NEW fixture family needs a matching test fn in BOTH hard-coded harnesses (neither globs directories) — see the Phase 07-02 `input.blocked` precedent.

### Extension (Tab Bridge)
- `extension/background.js` — the MV3 service worker: connection/backoff lifecycle, debounced full-snapshot builder, the 56 KB icon-stripping loop, the favicon base64 cache, and the `tabs.activate`/`tabs.close` command handlers. The bookmark snapshot + `bm.*` command handling clone these shapes.
- `extension/manifest.json` — permissions array (`tabs`, `tabGroups`, `favicon`, `alarms`); the `bookmarks` permission is added here. **See the deployment note in Specific Ideas.**
- `extension/README.md` — install/reload instructions the owner follows.

### Server
- `server/server-core/src/transport/ext.rs` — the loopback ext listener, single-extension policy, and the srv→ext command relay.
- `server/server-core/tests/ext_relay.rs` — the ext leg's contract tests (SPEC §15 has no codec harness; these tests plus the prose ARE the contract).
- `server/server-core/src/codec/json.rs` — Rust JSON codec; `SERVER_PROTO_VERSION` bump to 1.6 lives in this crate.
- `server/server-core/src/dispatch/router.rs` — routing + the executor-bound vs read classification, and the `browser_macro` vocabulary table.
- `server/server-core/src/transport/session.rs` — authed-gated push branches (the `tabs.changed` / `apps.changed` / `vol.changed` precedent for where a `bm.state`-derived push belongs).

### Client
- `app/remote_control/lib/browser/browser_screen.dart` — the screen being extended: tab section, `_TabRun` chunking, `_GroupBlock` containment, `_GroupHeader`, `kBrowserActions` + `BrowserMacroGrid`, and the row gesture map (tap-down activate, long-press/swipe close). 851 lines.
- `app/remote_control/lib/browser/tabs_store.dart` — `TabsViewState` + `TabsNotifier`: the value-equal view + `service.changes` subscription + primeList/activate/close command shape. The bookmarks store clones this.
- `app/packages/remote_protocol/lib/src/json_codec.dart` — Dart codec mirror; must stay byte-compatible with the Rust codec against shared fixtures.
- `app/remote_control/test/browser/browser_screen_test.dart` — the existing pinned contract for the tab section and macro vocabulary.
- `app/remote_control/lib/theme/tokens.dart` — the 7 locked D-12 palette tokens; the guard test forbids adding literals there. (Precedent: `kGroupColors` and `kTrackpadHintColor` ship as local non-token consts.)

### Phase-level
- `.planning/ROADMAP.md` — Phase 11 entry; `.planning/STATE.md` "Roadmap Evolution" carries the fuller entry-scan notes (a)–(e), explicitly marked as planning input, NOT locked decisions.
- `.planning/phases/10-.../10-CONTEXT.md` — the immediately prior phase's decision style and house-pattern list.
- `docs/superpowers/specs/2026-07-07-remote-control-design.md` — the approved design spec planning must follow.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`TabsNotifier` / `TabsViewState`** (`tabs_store.dart`, 110 lines): the exact template for a bookmarks store — value-equal state, `service.changes` subscription, `_view()` re-snapshot, `sendReliable` command methods. It is itself a clone of `AppsNotifier` minus favorites, so the pattern is twice-proven.
- **The extension's snapshot machinery**: debounced `scheduleSnapshot()`, full-query build, serialized-size budget loop, and reconnect-on-every-event guard already exist and generalize to a second snapshot type.
- **The srv→ext command relay** already carries `tabs.activate` / `tabs.close`; `bm.open` and the delete command are the same shape.
- **Confirm surfaces**: the Power screen owns `ConfirmTrackFsm` (slide-to-confirm) and a red countdown dialog. Neither is the right weight for bookmark deletion, but both establish the house approach to guarded destructive actions.
- **`_GroupBlock` / `_TabRun`** chunking shows how a nested, tinted, contained list section is built inside this screen.

### Established Patterns
- **Push has no after-auth snapshot** for `tabs.changed` / `apps.changed` / `clip.changed` — the client pulls on open. D-03 (lazy prime) extends this: the pull happens on first segment switch instead of screen open.
- **Additive optional wire fields** use `Option<T>` + serde `default` + `skip_serializing_if` (never emitted as null) — the `WindowInfo.icon/path` (1.2) and `TabEl.groupId` (1.5) precedent. A `TabEl.bookmarked` flag would follow it.
- **Enum-string leniency**: unknown enum values pass through the codec and render as a neutral fallback client-side (the `GroupEl.color` rule).
- **Fire-and-forget with self-healing snapshots**: `tabs.activate`/`tabs.close` get no `err` reply; stale ids correct themselves on the next push. D-12's optimistic star deliberately layers local state on top of this.
- **Vocabulary drift is caught by tests, not by types**: `kBrowserActions` ↔ router `browser_macro`, `kClientKeyCodes` ↔ `CLIENT_KEY_CODES`. Any new client-side `bm.*` vocabulary needs the same cross-check gate.
- **Privacy discipline in the extension**: tab titles, group titles and URLs are NEVER logged — lifecycle events and counts only. Bookmark titles and URLs inherit this rule.

### Integration Points
- `extension/manifest.json` permissions + `background.js` (new bookmark listeners, snapshot builder, `bm.*` command handlers).
- `ext.rs` (accept and relay the new ext-leg messages) → `session.rs` (authed-gated push branch) → `router.rs` (classify the new phone→server messages as executor-bound or read).
- Both codecs (`codec/json.rs`, `json_codec.dart`) + shared fixtures + `SERVER_PROTO_VERSION` → 1.6.
- `browser_screen.dart` gains the segmented control and the bookmarks list region; the macro grid and tab section stay structurally intact.

</code_context>

<specifics>
## Specific Ideas

- **Deployment note the owner should know (surfaced during scouting, not a decision):** adding the `bookmarks` permission to `extension/manifest.json` makes Chrome **disable the extension until the new permission is manually re-approved**. The tab list will appear disconnected on the phone until that happens. This needs to be called out in the extension README and in the phase's UAT steps — otherwise it reads as a regression.
- The star must be a **trailing button** specifically because the tab row's gesture budget is already spent — tap-down activates, long-press and swipe both close. This constraint came from the shipped implementation, not from preference.
- The owner chose a **truthful star with a confirm** over both a safe-but-lying bar-only star and a fire-on-tap delete: the star should never misreport state, and no single tap should destroy a curated bookmark.
- The **empty-folders-only** delete rule was chosen specifically to make a subtree wipe impossible, over both full folder deletion and no folder deletion at all.
- Segment switching must feel like a list swap, not a navigation — which is why the macro grid stays pinned (D-02).

</specifics>

<deferred>
## Deferred Ideas

- **Rename / move / reorder bookmarks, and create-folder** — real bookmark management; out of this phase's create-and-delete scope. Candidate for a later phase if the phone ever becomes a primary bookmark manager.
- **Bookmark search / filter** — a new capability, not a clarification of this one. Most valuable if the node cap ever proves too tight.
- **Non-empty folder deletion** — deliberately excluded by D-14; would need an undo story (Chrome's own undo toast does not exist on the phone) before it could ship.
- **Per-folder lazy fetch on the ext leg** — rejected for v1 (D-06) because it adds request/reply machinery to a push-only leg. Revisit only if a real bookmark tree overruns the 56 KB budget in practice.
- **Favicons on bookmark rows** — rejected for v1 (D-07) purely on payload budget; becomes possible if the wire ever moves to per-folder fetch.
- **Reusing an already-open tab instead of always opening a new one** — the phase scope is "open in a new tab"; URL-matching against open tabs is a separate behavior.

</deferred>

---

*Phase: 11-browser-bookmarks-view-open-star-current-tab*
*Context gathered: 2026-07-29 via in-session owner discussion*
