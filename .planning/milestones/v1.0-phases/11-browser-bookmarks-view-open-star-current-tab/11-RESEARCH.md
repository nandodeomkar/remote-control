# Phase 11: Browser bookmarks — view, open, star current tab - Research

**Researched:** 2026-07-29
**Domain:** Chrome MV3 `chrome.bookmarks` API + the shipped Tab Bridge ext leg (SPEC §15) + a new `bm.*` phone-facing wire family (proto 1.6) + a segmented Browser screen
**Confidence:** HIGH (codebase claims all file:line verified; external Chrome claims cited to developer.chrome.com and Chromium source; two items marked UNVERIFIED)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Placement & navigation**
- **D-01:** Bookmarks live behind a **Tabs | Bookmarks segmented control** at the top of the existing tab section on the Browser screen. The segment swaps only the list region — no new hub tile, no new screen, no separate route.
- **D-02:** The **7-button macro grid stays pinned below in BOTH segments.** Switching segments must not shift or hide surrounding chrome.
- **D-03:** **Lazy prime.** Screen open primes tabs only (today's `tabs.list`-on-open behavior is unchanged). The bookmark snapshot is requested the first time the user switches to the Bookmarks segment, and is kept live by push from then on.
- **D-04:** Opening a bookmark **leaves the user in the Bookmarks segment** — no auto-switch to Tabs. Several bookmarks can be opened in a row without losing the current folder position.

**List shape & wire payload**
- **D-05:** **Folder drill-down navigation** — not a flat capped list, not bookmarks-bar-only.
- **D-06:** The **whole tree ships in ONE `bm.state` snapshot** pushed by the extension; the phone navigates folders **locally**. No per-folder request/reply is added to the push-only ext leg. This requires a node cap plus a defined truncation story against the 56 KB frame budget (SPEC §15).
- **D-07:** **No favicons on bookmark rows** — folder glyph for folders, generic bookmark glyph for links. This is what keeps a node small enough (id + title + parent, no URL) for the whole tree to fit one frame.
- **D-08:** The **top level lists all Chrome roots as folders** (Bookmarks bar, Other bookmarks, Mobile bookmarks) so nothing in the collection is unreachable from the phone.

**Star / unstar**
- **D-09:** A **trailing star button on EVERY tab row** (not a single active-tab control). Tab rows already spend tap-down (activate), long-press and swipe (close), so a trailing button is the only free affordance.
- **D-10:** Starring files the new bookmark into the **bookmarks-bar root**, whose id is resolved via **`getTree()`** — never the hardcoded id `"1"`.
- **D-11:** **Truthful "anywhere" star:** filled = the tab's URL is bookmarked anywhere in the tree. Removing deletes **every matching-URL entry**, and is **confirm-gated** — never fire-on-tap.
- **D-12:** **Optimistic fill** — the star flips instantly on tap and reconciles against the next authoritative pushed snapshot. (Deliberately unlike the Media screen's mute, which has no optimistic flip.)

**Delete / manage scope**
- **D-13:** Bookmarks **can be deleted from inside the Bookmarks list**, reusing the **same confirm gate as unstar** — one deletion path, one safety story.
- **D-14:** **Folders are deletable only when empty.** A subtree wipe from the phone is structurally impossible; emptying a folder row by row is the price. The confirm still applies.

**Preserved invariants (locked upstream — not re-decided)**
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

### Deferred Ideas (OUT OF SCOPE)
- **Rename / move / reorder bookmarks, and create-folder** — real bookmark management; out of this phase's create-and-delete scope.
- **Bookmark search / filter** — a new capability, not a clarification of this one.
- **Non-empty folder deletion** — deliberately excluded by D-14; would need an undo story.
- **Per-folder lazy fetch on the ext leg** — rejected for v1 (D-06).
- **Favicons on bookmark rows** — rejected for v1 (D-07) purely on payload budget.
- **Reusing an already-open tab instead of always opening a new one** — out of scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

No REQ-IDs are mapped to this phase (added ad-hoc; extends the shipped Tab Bridge leg, adjacent to BROW-01). The locked decisions D-01..D-14 in CONTEXT.md are the acceptance surface. Requirement-to-research mapping is therefore decision-to-research:

| Decision | Research Support |
|----------|------------------|
| D-01/D-02 | §Client Integration Surface — insertion point `browser_screen.dart:344-361`, `Expanded`+pinned-grid layout recommendation |
| D-03 | §Client Integration Surface — `BookmarksNotifier.primeList()` fired on first segment switch, not `initState` |
| D-05/D-06/D-08 | §Payload Budget Math — flat BFS node list, cap 500, virtual root `"0"` |
| D-07 | §Payload Budget Math — no icon field on `BmEl` |
| D-09 | §Client Integration Surface — trailing star slot at `browser_screen.dart:810`, gesture-isolation test |
| D-10 | §chrome.bookmarks API Surface — `folderType === 'bookmarks-bar'` resolver with index-0 fallback |
| D-11 | §Star State — exact-URL `Set` from one `getTree()` walk; `search({url})` "matches verbatim" |
| D-12 | §Client Integration Surface — optimistic overlay set on `BookmarksViewState`/`TabsViewState` |
| D-13/D-14 | §chrome.bookmarks API Surface — Chrome's own `kFolderNotEmptyError` is the backstop; `count` on folder nodes gates the phone-side affordance |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

| Directive | Binding on this phase |
|-----------|----------------------|
| Tech stack locked: Flutter client, Rust server (tokio + tungstenite) | No new runtime; the extension stays vanilla MV3 JS |
| Transport: WebSocket only, JSON + 9-byte binary | `bm.*` is JSON text on the existing sockets. No new listener. |
| Security: LAN-only binding, ext leg loopback-only | Unchanged; but see §Security Domain — the accepted residual escalates |
| UI: dark minimal (#0E0F12, blue accent) | Segment control must clone the hand-rolled house pattern, not Material `SegmentedButton` |
| "What NOT to Use" table | Nothing in this phase adds a package. Zero new deps in `pubspec.yaml` / `Cargo.toml` / extension. |
| GSD Workflow Enforcement | No direct repo edits outside a GSD workflow |

**Privacy discipline (project-wide, enforced by convention in `extension/background.js:8-9` and `server/server-core/src/transport/ext.rs:11-14`):** tab titles, group titles, and URLs are NEVER logged. **Bookmark titles and URLs inherit this rule verbatim.**

## Summary

Phase 11 is a **wire-and-glue phase, not an unknown-technology phase**. Every mechanism it needs already ships: a loopback ext leg with a full-snapshot push (`ext.rs`), a watch→session→push chain (`session.rs`), a router read/executor-bound split (`router.rs`), a shared golden-fixture harness in both languages, a value-equal Riverpod store (`tabs_store.dart`), and a hand-rolled segmented control (`settings_screen.dart:409`). The phase's real work is cloning those six shapes once more, correctly, for bookmarks.

Three findings materially change the plan versus the CONTEXT.md scouting notes:

1. **The `bookmarks` permission does NOT disable this extension.** The deployment note in CONTEXT.md Specific Ideas describes the behavior for **packed / Web-Store-distributed** extensions. This extension is distributed as a zip the owner loads via **Load unpacked** (`extension/README.md:12-20`), and Chrome's own docs state *"No permission warnings will be displayed if an extension is loaded as an unpacked file"* [CITED: developer.chrome.com/docs/extensions/mv2/permission-warnings]. The owner presses the reload arrow; the permission is granted silently. The README/UAT should say *"press the reload arrow after updating"*, not *"the extension will be disabled"*. **This is still a mandatory UAT verification step** — see Assumptions Log A1.

2. **Chrome enforces D-14 for you.** `chrome.bookmarks.remove()` on a non-empty folder rejects with `kFolderNotEmptyError` = `"Can't remove non-empty folder (use recursive to force)."` [VERIFIED: chromium.googlesource.com bookmark_api_constants.cc]. `removeTree()` is the only recursive path and this phase simply never calls it. D-14 is therefore a *belt-and-braces* rule: gate the affordance phone-side on a folder child count, pre-check `children.length === 0` extension-side, and let Chrome's rejection be the third line.

3. **The existing 56 KB budget loop measures the wrong unit.** `extension/background.js:285-291` compares `frame.length` (a UTF-16 code-unit count) against `MAX_FRAME_BYTES = 57344`. For ASCII tab titles the two coincide; for CJK/emoji bookmark titles the real UTF-8 byte count is up to 3–4× larger. A bookmark tree is 10× the node count of a tab list and its titles are user-curated and frequently non-ASCII, so this latent bug becomes a live one: an oversize frame kills the ext session (`ext.rs:186-193` resets the watch unconditionally) and the phone flips to the install hint with no explanation. **The bookmark budget loop must measure `new TextEncoder().encode(frame).length`,** and fixing the existing tabs loop the same way is a cheap, in-scope hardening.

**Primary recommendation:** ship a **flat, breadth-first node list** (`BmEl {id, parentId, title, folder?, count?, locked?, truncated?}`, no URL, no icon) capped at **500 nodes / 48-char titles** with a **byte-measured trailing-drop loop**; add **six** phone-facing messages (`bm.list`, `bm.changed`, `bm.open`, `bm.star`, `bm.unstar`, `bm.remove`) and an **explicit tri-state `TabEl.bookmarked`** (`true`/`false`/absent-means-unknown); implement the star's truth via **one `getTree()` walk into a `Set<string>` of exact URLs**, shared with the bookmark snapshot builder.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Bookmark tree enumeration, node caps, title truncation | Extension (MV3 SW) | — | Only the extension has `chrome.bookmarks`. SPEC §15: caps enforced BEFORE send. |
| URL resolution (bookmark → tab, tab → bookmark match) | Extension (MV3 SW) | — | Locked invariant: no `url` crosses the phone-facing wire (SPEC §7). |
| Bookmark create / remove | Extension (MV3 SW) | — | Same reason; also the only tier that can catch Chrome's rejections. |
| Star truth computation (`TabEl.bookmarked`) | Extension (MV3 SW) | — | Needs both the tab URL and the bookmark URL set; neither may leave the machine's browser process. |
| Snapshot relay + belt truncation + session-death reset | Server (`server-core` ext.rs) | — | `run_ext` already owns the single-extension session and the watch reset. |
| Authed-gated push to the phone | Server (`session.rs`) | — | The `AuthState::Authed` guard is the T-06-01 privacy backstop. |
| Read/executor-bound classification, pause gate | Server (`router.rs`) | — | SPEC §11 lives there. |
| Codec parity + version bump | Both codecs + `protocol/fixtures/` | — | SPEC §14: shared fixtures, no per-language copies. |
| Folder drill-down navigation, back stack | Phone (`BookmarksNotifier`) | — | D-06: the phone navigates locally; the wire is push-only. |
| Optimistic star flip + reconcile | Phone (store) | — | D-12 is explicitly a client-local overlay on the authoritative snapshot. |
| Confirm gate before any delete | Phone (widget) | Extension (rejection) | D-11/D-13: no single tap destroys a bookmark. |

## Standard Stack

**No new packages, in any of the three ecosystems.** Everything this phase needs is already a direct dependency or a browser built-in.

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `chrome.bookmarks` | MV3 built-in | Tree read, create, remove, change events | The only API for this. Requires the `bookmarks` manifest permission. [CITED: developer.chrome.com/docs/extensions/reference/api/bookmarks] |
| `chrome.tabs` | MV3 built-in (already permitted) | `tabs.create({url})` for `bm.open`; `tabs.query({})` already used | `tabs.create` needs no additional permission |
| `serde` / `serde_json` | already in `server-core` | `BmNode` payload structs | The `TabInfo`/`GroupInfo` precedent (`executors/mod.rs:66-97`) |
| `flutter_riverpod` 3.x | already a direct dep | `BookmarksNotifier` | Clone of `TabsNotifier` (`tabs_store.dart:66`) |
| `material_symbols_icons` | already a direct dep | folder / bookmark / star glyphs | `icons_guard_test.dart` BANS classic `Icons.*` — must use `Symbols.*_rounded` |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `TextEncoder` | Web platform built-in (available in MV3 SW) | Byte-accurate frame sizing | Mandatory for the bookmark budget loop — see Pitfall 1 |
| `PrefsKv` / `SharedPrefsKv` | already in `lib/store/` | Persist the chosen segment (discretionary) | `KeyboardPadStore` precedent at `app/remote_control/lib/keyboard/key_rows.dart:285-319` |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Flat BFS node list | Nested `children[]` tree | ~19% cheaper on the wire (measured, §Payload Budget Math) but forces a recursive serde struct + recursive Dart parse (breaking the `_tabList`/`_groupList` helper shape at `json_codec.dart:117-155`), a recursive rebuild-and-remeasure truncation loop, and a flatten pass on the phone anyway to build the parent→children index D-05 needs. The saving does not change the cap tier. **Rejected.** |
| `chrome.bookmarks.search({url})` per tab | One `getTree()` walk → `Set<string>` | 50 IPC round-trips per 200 ms debounce vs 1 call already being made for the bookmark snapshot. **Rejected** — see §Star State. |
| `bookmarks` in `permissions` | `optional_permissions` + `chrome.permissions.request()` | `request()` *"must be requested from inside a user gesture"* [CITED: developer.chrome.com/docs/extensions/reference/api/permissions] and this extension has **no popup, no options page, no content script** (`manifest.json` declares only a `background.service_worker`). There is no gesture surface to call it from. **Structurally impossible.** |
| Hand-rolled segment control | Material `SegmentedButton` | M3 `SegmentedButton` brings a selected-fill, a check icon, and ripple theming that fight the dark-minimal palette; the app hand-rolls every segment/tab affordance already (3 precedents). **Rejected** — see §Client Integration Surface. |
| Two star messages (`bm.star`/`bm.unstar`) | One `bm.toggleStar` | A toggle races the optimistic flip (D-12): if a snapshot lands between tap and delivery, the toggle inverts the wrong state. Explicit star/unstar are idempotent. **Rejected.** |

**Installation:** none. Only `extension/manifest.json` changes:

```json
"permissions": ["tabs", "tabGroups", "favicon", "alarms", "bookmarks"]
```

## Package Legitimacy Audit

**Not applicable — this phase installs zero external packages.** No `npm install`, no `cargo add`, no `flutter pub add`. `chrome.bookmarks` is a browser built-in gated by a manifest permission string, not a package. The `package-legitimacy check` seam has no input.

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
                         ┌───────────────────────── PC (localhost) ─────────────────────────┐
                         │                                                                  │
  Chrome / Edge          │                    Remote Control server (Rust)                  │
 ┌────────────────┐      │  ┌────────────────────────────────────────────────────────────┐  │
 │ chrome.bookmarks│     │  │  run_ext (ext.rs) — ONE task, ONE session, newest-wins      │  │
 │  .onCreated     │     │  │                                                            │  │
 │  .onRemoved     │─┐   │  │   "bm.state"  ──▶ belt-truncate 500 ──▶ watch<BookmarksState>│ │
 │  .onChanged     │ │   │  │   "tabs.state"──▶ belt-truncate  50 ──▶ watch<TabsState>    │  │
 │  .onMoved       │ │   │  │   session end ──▶ RESET **BOTH** watches (CONN-07 clone)    │  │
 │  .onChildren…   │ │   │  │                                                            │  │
 │  .onImportBegan │ │   │  │   ExtCmd::BmOpen/BmStar/BmUnstar/BmRemove ──▶ ws.send ──────┼──┼─┐
 │ chrome.tabs.on*│ │   │  └────────────────────────┬───────────────────────────────────┘  │ │
 └────────┬───────┘ │   │                           │ watch                                 │ │
          │         │   │                           ▼                                       │ │
   ┌──────▼─────────▼─┐ │  ┌────────────────────────────────────────────────────────────┐  │ │
   │ background.js    │ │  │ session.rs — select! arm, gated `== AuthState::Authed`      │  │ │
   │  debounce 200ms  │ │  │   bm watch changed ──▶ bm.changed frame ──▶ phone           │  │ │
   │  buildBmSnapshot │ │  │ router.rs — bm.list = READ (pause-exempt)                   │  │ │
   │   getTree()      │ │  │              bm.open/star/unstar/remove = EXECUTOR-BOUND    │  │ │
   │   BFS walk       │ │  └────────────────────────┬───────────────────────────────────┘  │ │
   │   cap 500 nodes  │ │                           │ WebSocket (LAN, authed)              │ │
   │   title cap 48   │ │                           │                                       │ │
   │   TextEncoder    │ │  ─────────────────────────┼───────────────────────────────────────┘ │
   │    byte loop     │ │                           │                                         │
   │  buildTabSnapshot│ │                           │        srv→ext commands ────────────────┘
   │   urlSet from    │ │                           │
   │    same getTree  │ │                           ▼
   │   bookmarked:t/f │ │            ┌──────────────────────────────────┐
   └──────┬───────────┘ │            │  Phone (Flutter)                 │
          │  ws://127.0.0.1:17779    │  ConnectionService parks          │
          └──────────────────────────┤   BookmarksSnapshot + TabsSnapshot│
                                     │        │                          │
                                     │        ▼                          │
                                     │  BookmarksNotifier                │
                                     │   • value-equal view              │
                                     │   • currentFolderId + back stack  │  ← D-05 local nav
                                     │   • optimisticStars overlay       │  ← D-12
                                     │        │                          │
                                     │        ▼                          │
                                     │  BrowserScreen                    │
                                     │   [ Tabs | Bookmarks ] ← segment  │  ← D-01
                                     │   ┌─────────────────┐             │
                                     │   │ swapped region  │  Expanded   │
                                     │   └─────────────────┘             │
                                     │   BrowserMacroGrid  ← PINNED      │  ← D-02
                                     └──────────────────────────────────┘
```

### Recommended Project Structure

```
extension/
├── manifest.json           # + "bookmarks" permission
└── background.js           # + bookmark listeners, buildBmSnapshot, bm.* handlers,
                            #   urlSet shared into buildAndSend (tab snapshot)
protocol/
├── SPEC.md                 # §2 1.6 bullet, §7 bm.* rows + BmEl + TabEl.bookmarked,
                            #   §11 classification, §15 ext table rows + new caps
└── fixtures/
    ├── bookmarks/          # NEW family — needs a test fn in BOTH harnesses
    └── tabs/               # + 09-tabs-changed-bookmarked.json (existing harness covers it)
server/server-core/src/
├── executors/mod.rs        # + BmNode, BookmarksState, trait Bookmarks; Executors.bookmarks
├── codec/json.rs           # + BmListPayload/BmChangedPayload/BmOpen/BmStar/BmUnstar/BmRemove
│                           #   + TabInfo.bookmarked: Option<bool>
├── transport/ext.rs        # + ExtCmd variants, bm_tx param, "bm.state" arm, BOTH-watch reset
├── transport/session.rs    # SERVER_PROTO_VERSION → "1.6"; + authed-gated bm push arm
├── transport/mod.rs        # + ServerDeps.bookmarks watch receiver
└── dispatch/router.rs      # + bm.list read arm, 4 executor-bound arms, is_executor_bound
server/server-windows/src/main.rs   # + bm watch channel, wire into run_ext + ServerDeps
app/packages/remote_protocol/lib/src/json_codec.dart  # Dart mirror + BmNode + _bmList
app/remote_control/lib/browser/
├── browser_screen.dart     # + segment control, _BookmarksSection, trailing star slot
├── tabs_store.dart         # + optimistic star overlay (or a sibling file)
└── bookmarks_store.dart    # NEW — BookmarksNotifier (TabsNotifier clone + local nav)
```

### Pattern 1: Additive optional wire field (`Option<T>` + `default` + `skip_serializing_if`)

**What:** every protoVersion minor addition to an existing element uses the same three-part shape so a legacy peer's frame still decodes and canonically re-encodes without the key.
**When to use:** `TabEl.bookmarked`, and every optional `BmEl` field (`folder`, `count`, `locked`, `truncated`).

Rust — `server/server-core/src/executors/mod.rs:71-78` (the `groupId` precedent, protoVersion 1.5):

```rust
// Source: server/server-core/src/executors/mod.rs:71-78
#[serde(default, skip_serializing_if = "Option::is_none")]
pub icon: Option<String>,
#[serde(rename = "groupId", default, skip_serializing_if = "Option::is_none")]
pub group_id: Option<i64>,
```

Dart mirror — `app/packages/remote_protocol/lib/src/json_codec.dart:176-207`:

```dart
// Source: app/packages/remote_protocol/lib/src/json_codec.dart:176-195
final int? groupId;
Map<String, Object?> toJson() => {
      'id': id, 'title': title, 'active': active,
      if (icon != null) 'icon': icon,
      if (groupId != null) 'groupId': groupId,
    };
```

Parse side, `json_codec.dart:125-131`: `_opt<int>(e, 'groupId')`.

### Pattern 2: Full-snapshot ext relay with unconditional watch reset

**What:** the extension pushes a complete state on every change; the server never diffs, and resets the watch to `default()` on **any** session end (`ext.rs:110-198`).
**When to use:** the `bm.state` arm clones `handle_ext_text`'s `"tabs.state"` arm verbatim (`ext.rs:210-231`).

**Critical:** `run_ext` currently resets `tabs_tx` at **four** sites — `ext.rs:166`, `ext.rs:179`, `ext.rs:192`, and the send-failure path inside the incoming arm. **Every one must also reset `bm_tx`.** A missed site leaves a stale bookmark tree rendered on the phone after the browser closes, while the tab list correctly flips to the install hint — an incoherent screen.

### Pattern 3: Authed-gated push arm

**What:** an S→C push branch that only fires once the session is `Authed` (the T-06-01/T-TABS-02 privacy backstop).
**Source:** `server/server-core/src/transport/session.rs:331-346` (the tabs arm). The `bm` arm is a byte-discipline clone:

```rust
// Source: server/server-core/src/transport/session.rs:331-345 (tabs arm, to be cloned)
changed = tabs.changed(), if tabs_alive && ctx.auth_state == AuthState::Authed => {
    match changed {
        Ok(()) => {
            let state = tabs.borrow_and_update().clone();
            match tx.try_send(tabs_changed_frame(state)) { /* … */ }
        }
        Err(_) => tabs_alive = false,
    }
}
```

**No after-auth snapshot.** `tabs.changed` deliberately has none (`session.rs:324-330`) — the client pulls on open. D-03 extends that: `bm.list` is pulled on **first segment switch**. Do NOT add an after-auth `bm.changed` snapshot.

### Pattern 4: Read vs executor-bound classification

**Source:** `server/server-core/src/dispatch/router.rs:233-256` (tabs) and `:302-324` (`is_executor_bound`).

- `bm.list` joins the **read** group with `apps.list` / `clip.get` / `tabs.list` — answered while paused. Justification: it reads relay state, touches no executor, and the phone must render an honest empty/hint state even while input is paused.
- `bm.open`, `bm.star`, `bm.unstar`, `bm.remove` join `is_executor_bound` — silently dropped while paused. Justification: each mutates PC state (opens a tab / writes the bookmark database). Pause means "the phone must not change the PC."
- `bm.changed` joins the **S→C-only ignored** group at `router.rs:288-298` (a client sending it is silently ignored — the type IS known, so no `unknownType`).

### Pattern 5: Hand-rolled segmented control

**Source:** `app/remote_control/lib/settings/settings_screen.dart:409-485`. Two `Expanded` children with an 8px gap; each is a `Material(color: kBg)` + `InkWell` + `Container(minHeight: 40, border: selected ? kAccent : kHairline, radius 8)` with a 14/400 label coloured `kAccent` when selected, `kMuted` otherwise. Two sibling precedents: `KeyRowGroupSwitcher` (`key_rows.dart:668`) and `KeyboardTabBar` (`key_pads.dart:201-271`).

### Pattern 6: Value-equal store view + `service.changes` subscription

**Source:** `app/remote_control/lib/browser/tabs_store.dart:24-110`. `build()` watches `connectionServiceProvider`, subscribes `_service.changes`, cancels in `ref.onDispose`, and re-snapshots via `_view()`; commands go through `_service.sendReliable(...)`.

### Anti-Patterns to Avoid

- **Adding a `url` field "just for the star."** SPEC §7's no-url rule is a locked invariant and is enforced only by review + the fixture canonical form. Every URL comparison happens inside `background.js`.
- **Logging a bookmark title or URL.** `background.js` header (`:8-9`) and `ext.rs` header (`:11-14`) both forbid it. Log counts and lifecycle only. The existing snapshot log at `background.js:296-302` logs only counts — clone that shape.
- **Using `removeTree()` anywhere.** It is the one call that could wipe a subtree from the phone; D-14 exists to make that structurally impossible. `removeTree` must not appear in `background.js` at all — a grep gate is the cheapest enforcement.
- **Measuring the frame budget with `String.length`.** See Pitfall 1.
- **Reusing the field name `id` for both bookmark-node ids (strings) and tab ids (integers) across the `bm.*` family.** See Pitfall 4.
- **Registering `chrome.bookmarks.on*` listeners inside a callback or `async` body.** MV3 requires listeners *"declared in the global scope"* at *"the top level of the script and not be nested inside functions"* so they are *"registered synchronously on initial script execution"* [CITED: developer.chrome.com/docs/extensions/develop/concepts/service-workers/events]. `background.js:177-202` already follows this for tabs/tabGroups.
- **Adding a locked palette hex to any `lib/` file.** `test/theme_tokens_guard_test.dart:19-27` scans all of `lib/` for the 7 literals. Any new colour ships as a **local non-token const** — precedents: `kGroupColors` at `browser_screen.dart:73-83`, `kTrackpadHintColor` at `lib/trackpad/dot_grid.dart:42`. (These pass because their hex values are not among the 7 locked literals; a doc-comment mention is also exempt via the `startsWith('//')` skip at `theme_tokens_guard_test.dart:49`.)
- **Using classic `Icons.*`.** `test/icons_guard_test.dart:37-41` bans it with an intentionally **empty** allowlist. Use `Symbols.folder_rounded`, `Symbols.bookmark_rounded`, `Symbols.star_rounded` / `Symbols.star_outline_rounded`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Non-empty-folder protection | A recursive child-count check before every delete | `chrome.bookmarks.remove()`'s own rejection | Chrome already rejects with `kFolderNotEmptyError` [VERIFIED: chromium.googlesource.com]. Use the child count only to *hide the affordance*, not to *enforce the rule*. |
| Root-folder protection | A hardcoded blocklist of ids `"0"`,`"1"`,`"2"`,`"3"` | Chrome's `kModifySpecialError` = `"Can't modify the root bookmark folders."` | Ids are not guaranteed stable across profiles; the error is. |
| Managed-bookmark protection | Guessing which nodes are admin-locked | `BookmarkTreeNode.unmodifiable === "managed"` + catching `kModifyManagedError` | The field is documented and authoritative. |
| Bookmarks-bar id resolution | Hardcoding `"1"` (explicitly forbidden by D-10) or matching the title `"Bookmarks bar"` | `getTree()[0].children.find(n => n.folderType === 'bookmarks-bar')` | Title matching is **locale-dependent** (German: *Lesezeichenleiste*). `folderType` is a stable enum. |
| Exact URL matching semantics | Your own URL normalizer (strip fragment/query/trailing slash) | Raw exact string equality on Chrome's already-canonical URLs | Normalizing widens the blast radius of D-11's "delete EVERY matching entry" — see §Star State. |
| UTF-8 byte length of a JS string | `s.length`, or a manual code-point loop | `new TextEncoder().encode(s).length` | Platform built-in, correct for surrogate pairs, available in MV3 service workers. |
| Bookmark event de-duplication | Manual coalescing | The existing `scheduleSnapshot()` debounce (`background.js:204-207`) + an import-storm flag | Already proven for tabs; reuse it. |
| Frame-size enforcement on the server | Manual byte counting | `WebSocketConfig::max_message_size` already set at `ext.rs:116-118` | Oversize already kills the session cleanly and resets the watch. |

**Key insight:** the extension is the only tier that can see URLs, so every "is this bookmarked / where does this go / can this be deleted" question must be answered there — and Chrome already answers all of them with documented errors. The phone's job is purely to *not offer* what will be rejected; the extension's job is to *catch and ignore* what is rejected anyway; the full-snapshot push makes both self-healing.

## Runtime State Inventory

Not applicable — this is a **feature-addition** phase, not a rename/refactor/migration. No stored data, live service config, OS-registered state, secrets, or build artifacts carry a string that this phase changes.

One item that *looks* like runtime state and is worth stating explicitly: **the extension's installed copy on the owner's machine is loaded from an unzipped folder on disk** (`extension/README.md:33-35`). A `manifest.json` change in git does **not** reach that folder — the owner must re-download/re-unzip (or edit in place) **and press the reload arrow**. That is a UAT step, not a data migration.

## Payload Budget Math (D-06)

### Chosen node shape

```json
{"id":"1234","parentId":"562","title":"Some page title"}
```
plus, only when applicable (all `skip_serializing_if`):
`,"folder":true` (14 B) · `,"count":12` (11–13 B) · `,"locked":true` (14 B) · `,"truncated":true` (18 B)

No `url` (locked invariant), no `icon` (D-07), no `index`/`dateAdded` (not needed by any locked decision).

### Measured per-node cost (UTF-8 bytes, `JSON.stringify`, 4-digit ids)

| Title chars (ASCII) | Flat node | Nested node (no `parentId`) |
|---|---|---|
| 10 | 51 | 34 |
| 20 | 61 | 44 |
| 30 | 71 | 54 |
| 40 | 81 | 64 |
| 60 | 101 | 84 |
| 120 | 161 | 144 |

Fixed overhead of the flat shape = **41 bytes** + title bytes. Array comma = +1. Envelope `{"t":"bm.state","p":{"nodes":[…]}}` = **33 bytes** (+`connected`/`truncated` ≈ 60 total).

Realistic worst-case title: bookmark titles default to the page `<title>`, which routinely runs 60–90 characters (e.g. *"How to build a Rust WebSocket server - Stack Overflow"* = 52). Unbounded, a single node can exceed 200 bytes.

### Arithmetic for the cap

Assume **title cap 48 chars** (1.5× the SPEC §15 group-title cap of 32, because the bookmark row's title is its *only* content — no favicon, no URL) and 12% folders:

```
per-link node   = 41 + 48 + 1 (comma)                  =  90 B
per-folder node = 90 + 14 (folder) + 12 (count)        = 116 B
weighted mean   = 0.88 × 90 + 0.12 × 116               =  93 B
budget          = 57344 (56 KB) − 60 (envelope)        = 57284 B
max nodes       = 57284 / 93                           ≈ 616
```

**Recommended node cap: 500.** 500 × 93 + 60 = **46 560 B = 45.5 KB = 81% of the 56 KB budget**, leaving ~19% headroom for 5–6-digit ids on large profiles and for a handful of multi-byte titles. Simulation confirms: 500 nodes at a 48-char cap with 12% folders serialize to **45 414 B** flat / **36 915 B** nested — both fit.

**500 is also the right product number**, not just the right byte number: a 500-node cap covers the large majority of real personal bookmark collections, and D-05's drill-down means the phone never renders more than one folder's children at a time, so the phone-side cost of 500 nodes is a `Map` build, not 500 widgets.

### Why the cap alone is NOT sufficient

A CJK title at the 48-char cap is **144 UTF-8 bytes**, not 48. 500 such nodes = 41 + 144 + 1 = 186 B each → **93 KB** — past the 64 KB `max_message_size` (`ext.rs:37`, SPEC §13), which **kills the ext session** (`ext.rs:186-193`) and silently flips the phone to the install hint.

**Therefore the byte-measured drop loop is mandatory, not defensive.** And the same reasoning retroactively indicts the shipped tabs loop — see Pitfall 1.

### Recommended truncation story (Claude's Discretion — concrete recommendation)

**Walk order: breadth-first (level order), starting from the children of root `"0"`.**

Why BFS and not the DFS/pre-order that would be the "natural" tree walk: a pre-order truncation can exhaust the entire budget inside the *first* root's *first* deep subtree, leaving "Other bookmarks" and "Mobile bookmarks" entirely absent — a **direct violation of D-08** ("nothing in the collection is unreachable from the phone"). BFS guarantees that every root, and the top level of every root, is present before any depth-2 node is; degradation prunes the deepest leaves, which is exactly the least-navigable content.

**Drop procedure (extension-side, before send):**

1. BFS-collect nodes, skipping root `"0"` itself, capping titles at 48 chars, stopping at 500 nodes.
2. Serialize; while `new TextEncoder().encode(frame).length > 57344`, `pop()` the last node and re-serialize. (Identical control shape to the existing icon-strip loop at `background.js:286-291`, but popping whole nodes and measuring bytes.)
3. After the loop, for every node whose children were partially or wholly dropped, set `truncated: true` on that node; set `truncated: true` on the snapshot payload too.

**What the phone shows (Claude's Discretion — recommendation):** a **per-folder inline muted row**, not a global banner:

> `Some bookmarks in this folder aren't shown.` — 12/400 `kMuted`, rendered as the last row inside any folder whose node carries `truncated: true`.

Rationale: a global banner is noise on every screen for a condition that affects one or two deep folders; an inline row appears exactly where the user would otherwise be misled into thinking a folder is empty or complete. It also composes with the empty-folder copy (a folder that is both empty and truncated shows the truncation line, not "Empty folder"). This is the same "truthful, local, muted" posture D-11 takes with the star.

The snapshot-level `truncated` flag serves a second purpose: it lets the Bookmarks segment header show a one-line muted count (`"Showing 500 of your bookmarks"`) — optional, cheap, and honest.

### Flat vs nested, with numbers

| Config | Flat bytes | Nested bytes | Nested saving |
|---|---|---|---|
| 500 nodes, 32-char titles | 37 414 | 28 915 | 22.7% |
| 500 nodes, 48-char titles | 45 414 | 36 915 | 18.7% |
| 700 nodes, 48-char titles | 63 564 ✗ | 51 665 ✓ | 18.7% |

Nested is genuinely cheaper (the `parentId` key+value costs ~17 B on every node; `children:[]` costs ~14 B on only 12% of them). **Flat is still the recommendation** — see §Alternatives Considered. The saving buys ~120 extra nodes at the 56 KB line, which does not change the recommended cap of 500, and costs a recursive codec + recursive truncation + a phone-side flatten pass.

### SPEC §15 caps to add

```
max 500 bookmark nodes, bookmark titles capped at 48 chars, and if the
serialized `bm.state` frame exceeds 56 KB nodes are dropped from the END of
the breadth-first order until it fits. The server additionally truncates at
500 nodes as a belt.
```

## Star State: how `TabEl.bookmarked` gets computed (D-11)

### Does `search({url})` match exactly?

**Yes — verbatim.** [CITED: developer.chrome.com/docs/extensions/reference/api/bookmarks] The object form's `url` property is documented as *"The URL of the bookmark; matches verbatim. Note that folders have no URL."* (`title` is likewise *"matches verbatim"*; only the bare `query` string is word/phrase-based across URLs and titles.)

Two consequences:
- Exact matching is available and is the documented semantics — no fuzzy workaround is needed.
- **Folders can never appear in a `{url}` search result.** D-11's "removing deletes every matching-URL entry" therefore **cannot** touch a folder, so it cannot interact with D-14 at all. Confirmed, as CONTEXT.md asked.

### Recommended computation: one `getTree()` walk, not 50 searches

Build a `Set<string>` of every bookmark URL during the **same** `getTree()` walk that builds the `bm.state` snapshot, cache it in a module-level variable, and consume it in `buildAndSend()` (the tab snapshot builder at `background.js:214`):

```js
// Source pattern: extension/background.js:242-259 (tab element loop)
const el = { id: tab.id, title: tab.title ?? '', active: tab.id === activeId };
if (bmUrlSet !== null && tab.url) el.bookmarked = bmUrlSet.has(tab.url);
```

Reasoning:
- The bookmark snapshot already calls `getTree()`; the URL set is a free by-product of the walk it is already doing.
- 50 `chrome.bookmarks.search({url})` calls are 50 async IPC round-trips inside a 200 ms debounce (`DEBOUNCE_MS`, `background.js:28`). The existing per-tab `await favicon(url)` loop already serializes 50 awaits there (`background.js:254`); adding 50 more doubles the worst-case snapshot latency for no gain.
- Set membership on a canonical string is **semantically identical** to `search({url})`'s documented verbatim match, so truthfulness is not traded for speed.

**Wiring requirement:** because `bookmarked` lives on `TabEl`, every `chrome.bookmarks.on*` event must invalidate the URL set **and** schedule *both* snapshots. Concretely: a bookmark event schedules the bm snapshot (which rebuilds the set) and then the tab snapshot. Simplest correct implementation is one shared `scheduleSnapshot()` that rebuilds the URL set from `getTree()` and emits both `bm.state` and `tabs.state` — one debounce, one tree walk, two frames.

### URL normalization pitfalls

Chrome canonicalizes bookmark URLs through GURL on create (lowercases scheme+host, adds the trailing slash to a bare host, normalizes percent-encoding), and `tab.url` from `chrome.tabs.query` is likewise the GURL-canonical committed URL. So for the common case the two sides are already in the same canonical form and raw `===` works. The residual mismatches are **semantic**, not encoding:

| Case | Bookmark stores | Tab reports | Exact match? |
|---|---|---|---|
| Fragment | `https://x.com/doc#install` | `https://x.com/doc` | ✗ |
| Tracking query | `https://x.com/a` | `https://x.com/a?utm_source=…` | ✗ |
| Scheme | `http://x.com/` | `https://x.com/` | ✗ |
| Trailing slash on a bare host | `https://x.com/` | `https://x.com/` | ✓ (both canonical) |

**Recommendation: do NOT normalize. Use raw exact equality.** The decisive argument is not fidelity but blast radius: D-11 says unstar deletes **every** matching-URL entry. Any normalization (strip fragment, strip query, unify scheme) widens what "matching" means, so an unstar on `https://x.com/doc` would delete the user's carefully-kept `https://x.com/doc#install` bookmark too. Exact matching makes the star answer precisely *"this exact URL is bookmarked"* — which is the truthful reading of D-11 and the safe one.

The user-visible consequence to document in the plan: a star can read empty on a page whose *base* URL is bookmarked but whose current URL carries a fragment or query. That is honest, not a lie.

### `bookmarked` must be TRI-STATE, not skip-when-absent

The `icon`/`groupId`/`path` precedent uses skip-when-absent where absence means *"there is none."* Here absence would be ambiguous: it could mean *"not bookmarked"* or *"the extension could not read the bookmark tree."* Rendering an empty star for the second case is exactly the misreport D-11 forbids.

**Recommendation:** the extension emits `bookmarked` **explicitly as `true` or `false` on every tab** whenever the URL set was built successfully, and **omits the key entirely on every tab** when `getTree()` failed or the permission is missing.

- Cost: `,"bookmarked":false` = 20 B × 50 tabs = **1 000 B ≈ 1.7%** of the 56 KB budget. Affordable.
- Rust: `#[serde(default, skip_serializing_if = "Option::is_none")] pub bookmarked: Option<bool>` — the shape is unchanged from the `groupId` precedent; only the *meaning* of `None` changes (unknown, not false). Document that in the struct doc comment and in SPEC §7.
- Dart: `final bool? bookmarked;` with `_opt<bool>(e, 'bookmarked')`.
- Phone rendering: `true` → filled accent star; `false` → outline muted star; `null` → **no star button at all** (the row renders exactly as it does today).

### Unstar implementation (extension-side)

```
bm.unstar {tabId}
  → chrome.tabs.get(tabId)              → tab.url  (never leaves the machine)
  → chrome.bookmarks.search({url: tab.url})   → [nodes]  (folders impossible)
  → for each node without `unmodifiable`: chrome.bookmarks.remove(node.id).catch(() => {})
  → onRemoved events fire → debounced snapshot → phone reconciles
```

`.catch(() => {})` per node is required: a managed-bookmark node rejects with `kModifyManagedError`, and a node deleted concurrently rejects with `kNoNodeError`. Both are self-healing under the full-snapshot model — the same fire-and-forget posture as `tabs.activate` at `background.js:91-95`.

## Wire Contract Shape and Version Machinery

### Existing phone-facing family registry (SPEC §7, `protocol/SPEC.md:98-132`)

`hello`, `pin`, `pairOk`, `challenge`, `auth`, `authOk`, `authFail`, `click`, `drag`, `key`, `text`, `media`, `vol.changed`, `input.blocked`, `power`, `confirm`, `apps.list`, `apps.launch`, `apps.focus`, `apps.close`, `apps.changed`, `tabs.list`, `tabs.changed`, `tabs.activate`, `tabs.close`, `clip.set`, `clip.get`, `clip.changed`, `browser`, `present`, `ping`, `pong`, `err`.

House convention, derived: `<family>.<verb>`; `.list` = dual request/reply pull; `.changed` = S→C push; bare imperative verbs (`activate`, `close`, `focus`, `launch`, `set`, `get`) for commands. Abbreviated family prefixes are already in use (`clip`, `vol`), so `bm` fits.

### Recommended message set

| Type | Direction | Required `p` | Optional `p` | §11 class | Justification |
|------|-----------|--------------|--------------|-----------|---------------|
| `bm.list` | C→S request / S→C reply | request: — ; reply: `connected` (bool), `nodes` (array of BmEl) | reply: `truncated` (bool) | **READ** (pause-exempt) | Reads relay state only; touches no executor. Same exemption as `tabs.list`/`apps.list`/`clip.get` (SPEC §11). Fired on first Bookmarks-segment switch (D-03). |
| `bm.changed` | S→C push | `connected` (bool), `nodes` (array of BmEl) | `truncated` (bool) | S→C only | Authed-gated push on every relay change AND on extension connect/disconnect — the `tabs.changed` clone. Client sending it is silently ignored (`router.rs:288-298` group). |
| `bm.open` | C→S | `nodeId` (string) | — | **executor-bound** | Creates a new tab on the PC. Fire-and-forget, no `err` — stale ids self-heal on the next push (the `tabs.activate` posture). |
| `bm.star` | C→S | `tabId` (integer) | — | **executor-bound** | Writes the bookmark DB. Fire-and-forget. |
| `bm.unstar` | C→S | `tabId` (integer) | — | **executor-bound** | Deletes from the bookmark DB. Fire-and-forget. |
| `bm.remove` | C→S | `nodeId` (string) | — | **executor-bound** | Deletes one bookmark or one **empty** folder. Fire-and-forget. |

**BmEl element (protoVersion 1.6):**

`{id: string, parentId: string, title: string, folder?: bool, count?: integer, locked?: bool, truncated?: bool}`

- `id` and `parentId` are **strings** — Chrome bookmark ids are strings (`BookmarkTreeNode.id: string`, *"unique within the current profile… remain valid even after the browser is restarted"* [CITED: developer.chrome.com]). This is the one place the `bm.*` family deliberately diverges from `TabEl`'s integer `id`.
- `id`, `parentId`, `title` are **wire-required** (a missing field is a hard decode error — the `GroupEl` rule at SPEC §7 / `json_codec.dart:148-153`). Root `"0"` is never shipped as a node; its children carry `parentId: "0"` and the phone treats `"0"` as the virtual top level (D-08).
- `folder: true` marks a folder (absent = link). `count` is the folder's direct-child count — it drives the discretionary "folder child counts" UI **and** gates the D-14 delete affordance (`count == 0` ⇒ delete offered).
- `locked: true` mirrors `BookmarkTreeNode.unmodifiable` (managed/admin bookmarks) so the phone hides a delete that Chrome would reject with `kModifyManagedError`.
- `truncated: true` marks a folder whose children were dropped by the budget loop.
- **No `url`. No `icon`.** (Locked invariant + D-07.)

**TabEl addition (protoVersion 1.6):** `bookmarked?: bool` — tri-state, see §Star State.

**Distinct field names (`nodeId` vs `tabId`) are deliberate.** `bm.open`/`bm.remove` take a bookmark node id (string); `bm.star`/`bm.unstar` take a tab id (integer). Reusing `id` for both would put two different types behind one key name inside a single family — the codec is value-lenient (`router.rs` owns semantic validation), so a swap would decode fine and fail silently at the extension. The house has never mixed id types within a family; this is the first time it would, so name them apart.

### Ext-leg additions (SPEC §15 table, `protocol/SPEC.md:223-230`)

| Type | Direction | `p` | Notes |
|------|-----------|-----|-------|
| `bm.state` | ext→srv | `nodes` (array of BmEl); `truncated?` (bool) | ALWAYS a full snapshot, never a diff |
| `bm.open` | srv→ext | `nodeId` (string) | Same payload as the phone-facing message |
| `bm.star` | srv→ext | `tabId` (integer) | " |
| `bm.unstar` | srv→ext | `tabId` (integer) | " |
| `bm.remove` | srv→ext | `nodeId` (string) | " |

### The 1.5 → 1.6 version bump: every site

**CONTEXT.md says `SERVER_PROTO_VERSION` "lives in `codec/json.rs`". It does not.** Verified:

| # | Site | Current | Action |
|---|------|---------|--------|
| 1 | `server/server-core/src/transport/session.rs:60` | `pub const SERVER_PROTO_VERSION: &str = "1.5";` | → `"1.6"` — **the only Rust literal** |
| 2 | `server/server-core/src/transport/beacon.rs:56` | `"proto": SERVER_PROTO_VERSION` | references the const — no edit |
| 3 | `server/server-core/src/transport/mod.rs:22` | `pub use session::SERVER_PROTO_VERSION;` | no edit |
| 4 | `server/server-core/tests/integration.rs:650` | asserts against the const | no edit |
| 5 | `protocol/fixtures/beacon/01-valid.json:10` | `"proto": "1.5"` | → `"1.6"` (shared fixture, both codecs) |
| 6 | `protocol/fixtures/beacon/01-valid.json:16` | `"proto": "1.5"` | → `"1.6"` |
| 7 | `protocol/SPEC.md:3` | `**protoVersion:** "1.5"` | → `"1.6"` |
| 8 | `protocol/SPEC.md:32` | `Current version: "1.5"` | → `"1.6"` |
| 9 | `protocol/SPEC.md` §2 | after line 40 | add the **1.6 addition** bullet |
| 10 | `app/packages/remote_protocol/lib/src/version.dart:11` | `const String protoVersion = '1.1';` | **NO CHANGE** — this is the *client's* advertised version; the server parses only the major component (SPEC §2), and minor mismatch is explicitly accepted. Bumping it is optional and orthogonal. |
| 11 | `server/server-core/src/transport/session.rs:47-62` | doc block listing 1.1–1.5 additions | append a 1.6 line (the in-file changelog convention) |

The Phase-03-01 decision "SERVER_PROTO_VERSION widened to `pub(crate)` and referenced by `encode_beacon` — proto literal never duplicated" (STATE.md) is why only sites 1, 5, 6 are literal edits.

### The two hard-coded fixture harnesses

**Neither globs directories** — both enumerate *files within a named family*, but the family names themselves are hard-registered. Adding `protocol/fixtures/bookmarks/` without touching both harnesses yields **zero test coverage and zero failures** — silently. Precedents: `input.blocked` (07-02, STATE.md decision line) and `TabEl.groupId` (1.5).

| Language | File | Insert at | Shape to copy |
|---|---|---|---|
| Rust | `server/server-core/tests/fixtures.rs` | **after line 184** (`codec_fixtures_tabs`) | ```rust\n#[test]\nfn codec_fixtures_bookmarks() {\n    run_json_family("bookmarks");\n}\n``` — see `:168-184` |
| Dart | `app/packages/remote_protocol/test/fixture_test.dart` | **after line 202** (the `tabs fixtures` group) | ```dart\ngroup('bookmarks fixtures', () {\n  runJsonFamily('bookmarks');\n});\n``` — see `:186-202` |

Both harnesses drive the same three behaviours automatically once registered: `expect.error == true` ⇒ decode must throw; `expect` object ⇒ `encode(decode(wire))` must equal it order-insensitively (this is what proves D-05 unknown-field dropping); `05-auth-proof.json` skip-by-name is irrelevant here.

**Recommended `protocol/fixtures/bookmarks/` contents:**

| File | Proves |
|---|---|
| `01-bm-changed.json` | folder node (with `count`, `truncated`) + link node + `locked` node; an unknown `future` key on one node is dropped on re-encode (D-05); optional keys absent on the plain link stay absent |
| `02-bm-list-reply-never-connected.json` | `{connected:false, nodes:[]}` — the install-hint shape (the `02-tabs-list-reply.json` clone) |
| `03-bm-open.json` | `{nodeId:"1234"}` round trip |
| `04-bm-star.json` | `{tabId:7}` round trip |
| `05-bm-unstar.json` | `{tabId:7}` round trip |
| `06-bm-remove.json` | `{nodeId:"1234"}` round trip |
| `07-bm-node-missing-title.json` | `expect.error: true` — a missing required BmEl field is a hard decode error (the `08-tabs-group-missing-color.json` clone) |
| `08-bm-open-missing-nodeid.json` | `expect.error: true` (the `04-tabs-activate-missing-id.json` clone) |

**Plus one fixture in the EXISTING family** — `protocol/fixtures/tabs/09-tabs-changed-bookmarked.json`: three TabEls carrying `bookmarked:true`, `bookmarked:false`, and no `bookmarked` key, proving all three round-trip canonically. This needs **no new harness function** — `codec_fixtures_tabs` (`fixtures.rs:177`) and `group('tabs fixtures')` (`fixture_test.dart:200`) already enumerate every file in that directory.

## Client-Side Integration Surface

### Segmented control insertion point (D-01 / D-02)

Current widget tree, `app/remote_control/lib/browser/browser_screen.dart:330-368`:

```
SafeArea > Column
  ├─ ReconnectingBannerSlot            (:334-337)
  └─ Expanded > SingleChildScrollView  (:338-341, padding 16/32/16/16)
       └─ Column(stretch)              (:342)
            ├─ _SectionHeader('Tabs')  (:347)   ← REPLACE with the segment control
            ├─ SizedBox(height: 8)     (:348)
            ├─ _TabsSection(...)       (:349-354) ← SWAP: _TabsSection | _BookmarksSection
            ├─ SizedBox(height: 24)    (:355)
            └─ BrowserMacroGrid(...)   (:358-361) ← must stay pinned (D-02)
```

**Recommendation for D-02:** D-02 has two readings — (a) structural ("the grid is present below in both segments") and (b) pixel-pinned ("the grid does not move"). The CONTEXT.md Specific Ideas line *"Segment switching must feel like a list swap, not a navigation — which is why the macro grid stays pinned"* selects reading **(b)**. Under the current single-`SingleChildScrollView` layout the grid **will** shift vertically when the list region's height changes between segments, so reading (b) requires a layout change:

```
SafeArea > Column
  ├─ ReconnectingBannerSlot
  ├─ Padding(16,32,16,0) > _BrowserSegment(current, onSelect)   ← NEW, fixed height
  ├─ Expanded                                                    ← the swapped region
  │    └─ SingleChildScrollView(padding 16,8,16,8)
  │         └─ segment == Tabs ? _TabsSection(...) : _BookmarksSection(...)
  └─ Padding(16,16,16,16) > BrowserMacroGrid(...)                ← PINNED, outside the scroll
```

Risk check: `test/browser/browser_screen_test.dart` pumps on an 800×1600 surface (`:107`) so nothing depends on the grid being reachable only by scrolling, and no test asserts `find.text('Tabs')` (verified — the only literal string assertions are `'Install the browser extension'` at `:329` and `:364`). The 7-button-tap test (`:211`) taps by label and will still find the pinned grid. **The layout change is safe against the existing suite.** The `_TabsSection` / `_GroupBlock` / `_TabRun` / `_GroupHeader` / `_TabRow` structures at `:393-723` stay byte-untouched.

**Segment control widget:** clone `_ScrollDirectionSegment` + `_SegmentButton` (`settings_screen.dart:409-485`) — two `Expanded` children, 8px gap, `Material(kBg)` + `InkWell` + `Container(minHeight: 40, radius 8, border: selected ? kAccent : kHairline)`, label 14/400 `kAccent`/`kMuted`. Do **not** use Material's `SegmentedButton`: the app has three hand-rolled precedents (`_ScrollDirectionSegment`, `KeyRowGroupSwitcher` at `key_rows.dart:668`, `KeyboardTabBar` at `key_pads.dart:201`) and zero uses of any Material tab/segment widget (`grep SegmentedButton|ToggleButtons|TabBar(` returns only these house widgets). Follow `KeyboardTabBar`'s explicit rule (`key_pads.dart:188-192`): **the segment is navigation, not a send — it must work offline and unauthed, with no `enabled` parameter.**

**Segment persistence (Claude's Discretion — recommendation):** persist it, using the `KeyboardPadStore` pattern (`key_rows.dart:285-319`: a `PrefsKv`-backed store under a namespaced key, provider-overridable in tests) with the key `browser.segment`. It is ~25 lines, matches a Phase-10 precedent the owner already approved, and D-04's "several bookmarks in a row without losing position" logic wants the segment sticky within a session anyway. If the planner wants to defer, session-only (screen-state) persistence still satisfies D-04; cross-restart persistence is the nice-to-have.

### `BookmarksNotifier` — what changes from `TabsNotifier`

`tabs_store.dart` is 110 lines and the clone is close to mechanical. **Unchanged shapes** (`tabs_store.dart:66-110`): `Notifier<T>` with `build()` watching `connectionServiceProvider`, `_sub = _service.changes.listen((_) => _onChange())`, `ref.onDispose` cancel, `_view()` re-snapshot, `sendReliable(...)` command methods, and a hand-rolled element-wise `operator ==` / `hashCode` (`:43-60`) — **no `package:collection`** (Phase-06-03 decision: it is not a direct dep).

**What must change / be added:**

| Concern | Change |
|---|---|
| Snapshot source | `_service.bookmarksSnapshot` — a new parked `BookmarksSnapshot` on `ConnectionService`, cloning the `TabsSnapshot` parking at `connection_service.dart:163-190` (class), `:309` (field), `:412` (getter), `:660-671` (`TabsChangedMsg` arm), `:672-680` (`TabsListMsg` arm) |
| Prime trigger | **NOT** `initState` (that stays tabs-only per D-03). `primeList()` is called from the segment's `onSelect` handler, guarded by a `bool _bmPrimed` so it fires once per screen mount. |
| **Local navigation state (NEW)** | `String currentFolderId` (init `"0"` — the virtual root) + `List<String> backStack`. Both live in the notifier's state so a rebuild from a push preserves position (D-04's "without losing the current folder position"). `enterFolder(id)` pushes; `goBack()` pops; `goBack()` at depth 0 returns false so the screen can let `PopScope` leave the route. |
| **Children index (NEW)** | `_view()` builds `Map<String, List<BmNode>> childrenByParent` once per snapshot from the flat list. Sort within a folder: folders first, then links, each in wire order (the extension emits BFS which preserves Chrome's own index order within a parent) — matching Chrome's own bookmark-manager ordering. |
| **Stale-folder healing (NEW)** | If `currentFolderId` is absent from the new snapshot (folder deleted on the PC), reset to `"0"` and clear the back stack. Silent, self-healing — the fire-and-forget posture. |
| **Optimistic star overlay (NEW, D-12)** | `Set<int> _optimisticStarred` / `_optimisticUnstarred` keyed by tab id. `star(id)` adds to the first set and removes from the second (and vice versa) then sends. The tab view's effective `bookmarked` = overlay if present, else the snapshot value. **Every incoming snapshot clears both sets entirely** — the pushed value is authoritative, whether or not it agrees. That is the plain reading of D-12 "reconciles against the next authoritative pushed snapshot," it is one line, and it cannot leak a stale optimistic bit. |
| Value equality | Include `currentFolderId`, the back-stack length, and the two overlay sets in `==`/`hashCode`, or the segment will not rebuild on a drill-down. |

Note: the optimistic star overlay is per-*tab*, so it may live on `TabsNotifier` rather than `BookmarksNotifier`. Recommendation: put it on `TabsNotifier` (the star renders on a tab row) and keep `BookmarksNotifier` purely about the tree — one owner per surface.

### Trailing star button (D-09)

Insertion point: `browser_screen.dart:795-811`, the `Row` inside `_TabRow.build`:

```dart
// Source: app/remote_control/lib/browser/browser_screen.dart:795-811
Row(children: [
  _TabIcon(iconB64: widget.tab.icon, size: 24),   // :797
  const SizedBox(width: 8),                        // :798
  Expanded(child: Text(...)),                      // :799-810
  // ← INSERT the star slot HERE, after the Expanded, before the closing ]
])
```

**Gesture-map collision analysis.** The row's spent budget (`_TabRow.build`, `:785-790` + the `Dismissible` at `:510-535`):

| Gesture | Owner | Effect |
|---|---|---|
| tap-down | `InkWell.onTapDown` (`:788`) | activate + 100 ms accent flash |
| tap | `InkWell.onTap` (`:787`) | no-op (present so the InkWell participates) |
| long-press | `InkWell.onLongPress` (`:789`) | close |
| horizontal drag | `Dismissible` (`:510-527`) | close (springs back; `confirmDismiss` returns false at `:545-549`) |

The star must be a **separate gesture surface nested inside** the row so Flutter's arena resolves the tap to the innermost recognizer. Recommendation:

```dart
SizedBox(
  width: 44, height: 44,                       // ≥44 touch target
  child: InkWell(
    customBorder: const CircleBorder(),
    onTap: widget.enabled ? () => widget.onStar(widget.tab.id, filled) : null,
    child: Icon(filled ? Symbols.star_rounded : Symbols.star_outline_rounded,
                size: 20, color: filled ? kAccent : kMuted),
  ),
)
```

Residual risks to pin with tests, not reasoning:
1. **Parent `onTapDown` must not fire.** Flutter resolves nested taps to the innermost recognizer, but `TapGestureRecognizer.onTapDown` has deadline-based firing semantics. **Test:** tap the star ⇒ `onStar` fires exactly once **and** `sendReliable` records **zero** `TabsActivateMsg`.
2. **Horizontal drag starting on the star** is still claimed by the `Dismissible` (drag ≠ tap) — that is correct and unchanged; no test needed beyond the existing swipe test at `:401`.
3. **The star must be inert when `!enabled`** (`onTap: null`) — the gated-muted-not-red rule. **Test:** disabled screen, tap star, nothing recorded.
4. `bookmarked == null` ⇒ **render no star slot at all** (see §Star State), so the row is byte-identical to today's when the extension cannot see bookmarks.

### `tokens.dart` guard — the local-const escape hatch

`test/theme_tokens_guard_test.dart:30-66` scans every `.dart` under `lib/` (excluding `lib/theme/tokens.dart`) for the seven locked hex literals (`:19-27`), skipping lines whose trimmed content starts with `//` (`:49`). Precedents for shipping a new colour **outside** `tokens.dart`:

- `kGroupColors` — `app/remote_control/lib/browser/browser_screen.dart:73-83` (9 Chrome group swatches, top-level `const Map<String, Color>`, with the rationale in the doc comment at `:68-72`: *"These are NEW local consts, NOT theme tokens"*)
- `kTrackpadHintColor` — `app/remote_control/lib/trackpad/dot_grid.dart:42`

This phase most likely needs **zero** new colours: `kAccent` (filled star, selected segment), `kMuted` (outline star, folder glyph, truncation copy), `kText`, `kSurface`, `kHairline` cover everything. If a bookmark-specific tint is wanted, follow the `kGroupColors` shape and keep it local to `browser_screen.dart`.

### Icons

`test/icons_guard_test.dart` bans classic `Icons.*` with an **empty** allowlist (`:37`). Use: `Symbols.folder_rounded`, `Symbols.bookmark_rounded`, `Symbols.star_rounded`, `Symbols.star_outline_rounded`, `Symbols.arrow_back_rounded` (already imported at `browser_screen.dart:112` for the macro grid), `Symbols.delete_rounded`.

## Common Pitfalls

### Pitfall 1: The 56 KB budget loop measures characters, not bytes

**What goes wrong:** the frame passes the extension's `frame.length > MAX_FRAME_BYTES` check but exceeds 64 KB on the wire; `ext.rs`'s `max_message_size` kills the session; the watch resets to `TabsState::default()`; the phone flips to "Install the browser extension" with the extension visibly running.
**Why it happens:** `extension/background.js:285-291` uses `frame.length`, a UTF-16 code-unit count. A CJK character is 1 unit but 3 UTF-8 bytes; an emoji is 2 units but 4 bytes. Tab titles are mostly ASCII so the bug never fired; bookmark titles are user-curated, longer, and far more often non-ASCII, across a 10× larger node count.
**How to avoid:** measure with `new TextEncoder().encode(frame).length` in the new bookmark loop, **and** fix the existing tabs loop the same way (cheap, in-scope hardening).
**Warning signs:** the phone shows the install hint while `chrome://extensions` shows the service worker active; the SW console logs a snapshot-sent line immediately before a `[tab-bridge] disconnected`.

### Pitfall 2: `run_ext` resets only one watch on session death

**What goes wrong:** the browser closes; the tab list correctly empties to the install hint but the Bookmarks segment keeps rendering a stale tree the user can tap. `bm.open` then silently no-ops (`ext.rs:169-170`: no session ⇒ command dropped).
**Why it happens:** `ext.rs` resets `tabs_tx` at **four** independent sites — the send-failure path (`:164-167`), the pong-send-failure path (`:177-181`), the stream-end/error arm (`:190-193`), and each is easy to miss when threading a second sender through.
**How to avoid:** extract a `fn reset_all(tabs_tx, bm_tx)` helper and call it at every site, so a future third watch cannot regress.
**Warning signs:** `ext_relay.rs`'s `ext_disconnect_resets_watch` (`:126-143`) passes while a bookmarks equivalent fails.

### Pitfall 3: The import storm

**What goes wrong:** a bookmark HTML import fires hundreds of `onCreated` events; the 200 ms debounce coalesces them but `buildAndSend` runs a full `getTree()` on every settling gap during a multi-second import, and the tree is huge and growing.
**Why it happens:** Chrome documents the mitigation explicitly: *"Fired when a bookmark import session is begun. Expensive observers should ignore onCreated updates until onImportEnded is fired."* [CITED: developer.chrome.com/docs/extensions/reference/api/bookmarks]
**How to avoid:** a module-level `let importing = false;` set by `onImportBegan`, cleared by `onImportEnded` (which then calls `scheduleSnapshot()` once). While `importing`, bookmark events are ignored. Both listeners registered at top level like every other listener in the file.
**Warning signs:** the SW console spams snapshot-sent lines during an import; the phone list flickers.

### Pitfall 4: `id` means two different types across the `bm.*` family

**What goes wrong:** `bm.star {id: 7}` (tab id) and `bm.open {id: "1234"}` (node id) both decode fine — the codec is value-lenient by design (Phase-01 decision: *"Enum-valued wire fields are plain Strings in codec payload structs: codec stays value-lenient, semantic validation lives in the router"*). A swap surfaces only as a silent no-op inside the extension.
**How to avoid:** name them `nodeId` (string) and `tabId` (integer). Distinct names make the Rust struct types (`String` vs `i64`) the enforcement, and a fixture with the wrong type becomes a hard decode error.
**Warning signs:** none at build time — that is the point.

### Pitfall 5: `getTree()` includes the root; the phone must not render or delete it

**What goes wrong:** shipping root `"0"` as a node gives the phone a top-level folder called `""` that a user can try to delete, which Chrome rejects with `kModifySpecialError` ("Can't modify the root bookmark folders."), and D-08's "top level lists all Chrome roots" renders one level too deep.
**How to avoid:** the BFS walk starts at `getTree()[0].children`, never emits node `"0"`, and the phone treats `currentFolderId == "0"` as the top level. The roots themselves (Bookmarks bar / Other / Mobile / Managed) are unmodifiable too — mark them `locked: true` from `unmodifiable` so the delete affordance never appears on them either.

### Pitfall 6: Locale-dependent bookmarks-bar resolution

**What goes wrong:** `getTree()[0].children.find(n => n.title === 'Bookmarks bar')` returns `undefined` on a German/Japanese/Spanish Chrome; `create({parentId: undefined})` then files the bookmark into "Other bookmarks" — a silent D-10 violation.
**How to avoid:** `find(n => n.folderType === 'bookmarks-bar')` [CITED: developer.chrome.com — `folderType` enum `bookmarks-bar|other|mobile|managed`, Chrome 134+], with `?? tree[0].children[0]` as the fallback for a fork or a pre-134 build. Never a hardcoded `"1"` (D-10 forbids it explicitly).
**Warning signs:** a starred tab appears under Other bookmarks instead of the bar.

### Pitfall 7: A silent fixture family

**What goes wrong:** `protocol/fixtures/bookmarks/` is created and populated; both test suites stay green; the family is never exercised in either language. This is the documented 07-02 `input.blocked` lesson (STATE.md: *"A NEW fixture family needs a matching test fn in BOTH hard-coded harnesses… neither globs dirs"*).
**How to avoid:** the two one-line registrations at `fixtures.rs:184` and `fixture_test.dart:202`. Sanity-check by deliberately corrupting one fixture's `expect` and confirming **both** suites go red.

### Pitfall 8: Nested-tap arena resolution on the star

See §Client-Side Integration Surface. Pin it with a test asserting **zero** `TabsActivateMsg` on a star tap — do not rely on reasoning about `TapGestureRecognizer` deadlines.

### Pitfall 9: `bookmarks.get(nodeId)` on a folder has no `url`

**What goes wrong:** `bm.open` on a folder id calls `chrome.tabs.create({url: undefined})`, which opens the new-tab page — a confusing no-op.
**How to avoid:** the extension guards `if (!node.url) return;`. The phone should never send it (folder rows drill down, they do not open), but the extension is the tier that must not trust its input.

### Pitfall 10: An `err` reply where the family has none

**What goes wrong:** adding `err {code:"bookmarkGone"}` to `bm.remove` introduces a reply path the `tabs.*` family deliberately does not have, and the client has no consumer for it.
**How to avoid:** keep the whole `bm.*` command set **fire-and-forget with no `err`**, exactly like `tabs.activate`/`tabs.close` (SPEC §7: *"Fire-and-forget — no err reply; stale ids self-heal via the next `tabs.changed`"*). Every failure mode here self-heals via the next full snapshot. Do not add new `err` codes to SPEC §7's table.

## Code Examples

### Resolving the bookmarks-bar root (D-10)

```js
// Source pattern: developer.chrome.com/docs/extensions/reference/api/bookmarks
//   BookmarkTreeNode.folderType enum = bookmarks-bar | other | mobile | managed
async function bookmarksBarId() {
  const tree = await chrome.bookmarks.getTree();          // [root "0"]
  const roots = (tree[0] && tree[0].children) || [];
  const bar = roots.find((n) => n.folderType === "bookmarks-bar") || roots[0];
  return bar ? bar.id : null;                              // NEVER the literal "1"
}
```

### BFS snapshot + byte-measured budget loop (D-06)

```js
// Shape cloned from extension/background.js:284-291 (the icon-strip loop),
// but popping whole nodes and measuring BYTES (Pitfall 1).
const MAX_BM_NODES = 500;
const MAX_BM_TITLE = 48;
const MAX_FRAME_BYTES = 57344;              // 56 KB, SPEC §15

function bytes(s) { return new TextEncoder().encode(s).length; }

async function buildBmSnapshot() {
  const tree = await chrome.bookmarks.getTree();
  const nodes = [];
  const urls = new Set();
  const queue = [...((tree[0] && tree[0].children) || [])];   // skip root "0"
  let dropped = new Set();                                     // parentIds with dropped kids
  while (queue.length) {
    const n = queue.shift();
    if (nodes.length >= MAX_BM_NODES) { dropped.add(n.parentId); continue; }
    const el = {
      id: n.id,
      parentId: n.parentId !== undefined ? n.parentId : "0",
      title: (n.title || "").slice(0, MAX_BM_TITLE),
    };
    if (n.children !== undefined) { el.folder = true; el.count = n.children.length; }
    else if (n.url) { urls.add(n.url); }                       // exact-URL star set (D-11)
    if (n.unmodifiable) el.locked = true;
    nodes.push(el);
    if (n.children) queue.push(...n.children);
  }
  // Byte-measured trailing drop.
  let frame = JSON.stringify({ t: "bm.state", p: { nodes } });
  while (nodes.length && bytes(frame) > MAX_FRAME_BYTES) {
    dropped.add(nodes.pop().parentId);
    frame = JSON.stringify({ t: "bm.state", p: { nodes } });
  }
  if (dropped.size) {
    for (const el of nodes) if (dropped.has(el.id)) el.truncated = true;
    frame = JSON.stringify({ t: "bm.state", p: { nodes, truncated: true } });
  }
  return { frame, urls };                    // urls feeds TabEl.bookmarked
}
```

*(Illustrative — NOT a spec. The planner owns the final structure; the load-bearing parts are: skip root `"0"`, BFS order, title cap, `TextEncoder` measurement, and the shared `urls` set.)*

### Rust: the additive tri-state `TabInfo.bookmarked`

```rust
// Source pattern: server/server-core/src/executors/mod.rs:71-78 (groupId precedent)
/// Whether this tab's URL is bookmarked ANYWHERE in the PC's bookmark tree
/// (protoVersion 1.6). Unlike `icon`/`group_id`, `None` here means UNKNOWN —
/// the extension could not read the bookmark tree — NOT "not bookmarked".
/// The extension emits an explicit `true` or `false` on every tab whenever
/// the URL set was built; it omits the key on every tab when it was not.
#[serde(default, skip_serializing_if = "Option::is_none")]
pub bookmarked: Option<bool>,
```

### Dart mirror

```dart
// Source pattern: app/packages/remote_protocol/lib/src/json_codec.dart:125-131, 189-195
TabInfo(
  id: _req<int>(e, 'id'),
  title: _req<String>(e, 'title'),
  active: _req<bool>(e, 'active'),
  icon: _opt<String>(e, 'icon'),
  groupId: _opt<int>(e, 'groupId'),
  bookmarked: _opt<bool>(e, 'bookmarked'),   // tri-state: null == unknown
);
// toJson():  if (bookmarked != null) 'bookmarked': bookmarked,
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|---|---|---|---|
| `chrome.bookmarks.*(args, callback)` | `await chrome.bookmarks.*(args)` — all methods return `Promise` | Chrome 90 | The extension's existing `.then()/.catch()` style at `background.js:91-99` applies unchanged |
| Identify a special folder by hardcoded id (`"1"`) or by localized title | `BookmarkTreeNode.folderType` enum | Chrome 134 | The only locale-safe, id-stable resolver — resolves D-10 cleanly |
| `MAX_WRITE_OPERATIONS_PER_HOUR` / `MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE` quota constants | Deprecated: *"Bookmark write operations are no longer limited by Chrome"* | — | D-11's "delete EVERY matching entry" cannot hit a write quota, even on a URL bookmarked 50 times |
| MV2 persistent background page holding state | MV3 stateless service worker + full snapshots | MV3 | Already the shipped design (`background.js:210-212`); bookmarks inherit it verbatim |

**Deprecated/outdated:**
- **`chrome.bookmarks` callback overloads** — promise-only in current docs; use `await`/`.catch()`.
- **The bookmark write-quota constants** — documented as deprecated and non-enforcing.
- **`removeTree()` for this phase** — not deprecated by Chrome, but **banned by D-14**. Recommend a grep gate in the plan.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|---|---|---|
| A1 | Adding `bookmarks` to `manifest.json` does **not** disable this extension, because it is loaded unpacked. Sourced from the **MV2-era** permission-warnings page (*"No permission warnings will be displayed if an extension is loaded as an unpacked file"*); no MV3-era page restates it. | Summary finding 1 | If wrong, the owner's tab list dies until a manual re-enable and reads as a regression. **Mitigation: a mandatory UAT step (see Validation Architecture UAT-1) that reloads the extension and confirms it stays enabled — this is cheap and settles A1 on the owner's actual Chrome build.** The README wording should be written after that step, not before. |
| A2 | `folderType` is present on the owner's Chrome/Edge (requires Chrome 134+; current stable is far past that). | Pitfall 6 | Falls back to `roots[0]` — which IS the bookmarks bar in every Chromium build — so the failure mode is benign. Verified only by the docs' "Chrome 134+" annotation, not on the owner's machine. |
| A3 | `getTree()` on a large profile completes fast enough to sit inside the existing 200 ms debounce without a perceptible snapshot delay. Chrome's bookmark model is fully in-memory, so this is near-certain, but it is **UNVERIFIED** — no measurement was taken. | Star State | A slow `getTree()` on a 5 000-node profile would delay both snapshots. Measurable in the SW console during UAT (`console.time`). |
| A4 | 12% of nodes are folders (used in the weighted-mean byte arithmetic). | Payload Budget Math | A folder-heavy profile shifts the mean to ~116 B/node ⇒ ~494 nodes at 56 KB — the byte-measured drop loop absorbs it, so the cap of 500 remains safe. |
| A5 | Bookmark titles are frequently non-ASCII for this owner. | Pitfall 1 | If wholly ASCII, the `TextEncoder` fix is harmless belt; the pitfall is real regardless because it also protects the shipped tabs path. |
| A6 | Flutter resolves the nested star tap to the inner `InkWell` without firing the parent's `onTapDown`. | Client Integration | **Explicitly pinned by a test rather than trusted** — see Validation Architecture row for D-09. |

## Open Questions (RESOLVED)

1. **Does the owner's Chrome disable the extension on the permission change?** — **RESOLVED: deferred by design to UAT-1 (11-12 task 2).** Both outcomes are acceptable; the README prose is written from the observed result, never before it.
   - What we know: packed extensions are disabled pending re-approval; unpacked ones are documented to receive no permission warnings at all.
   - What's unclear: whether current-stable Chrome still honours the MV2-era unpacked exemption in the same way.
   - **Recommendation:** treat it as unknown in the plan. UAT-1 (below) resolves it in 60 seconds on the owner's machine, and the README/UAT copy is written from the observed result. Do **not** ship README prose asserting either behaviour before that step runs.

2. **Should the truncation flag be per-folder, snapshot-level, or both?** — **RESOLVED: both** (implemented by 11-05 task 3).
   - What we know: per-folder is more truthful; snapshot-level is cheaper and enables a header count.
   - **Recommendation:** both. `truncated` on affected folders (skip-when-absent, so free in the normal case) drives the inline row; `truncated` on the payload drives the optional header line. Total marginal cost in an untruncated snapshot: **0 bytes.**

3. **Does the star belong on `TabsNotifier` or `BookmarksNotifier`?** — **RESOLVED: `TabsNotifier`** (implemented by 11-08 task 3).
   - **Recommendation:** `TabsNotifier`. The star renders on a tab row, reads `TabEl.bookmarked`, and its optimistic overlay is keyed by tab id. `BookmarksNotifier` stays purely about the tree. One owner per surface.

4. **Should the existing tabs budget loop be fixed in this phase?** — **RESOLVED: yes** (implemented by 11-05 task 1; on-device coverage named there as UAT-3 + UAT-11).
   - What we know: it is a live latent bug (Pitfall 1) in code this phase is already editing.
   - **Recommendation:** yes — a two-line change in the same function, in the same file, with the same reasoning. Note it explicitly in the plan so it is not mistaken for scope creep.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|---|---|---|---|---|
| Rust toolchain + cargo | `server-core` build/tests | ✓ | edition 2024 (project builds; CI runs `cargo test --workspace`, `.github/workflows/ci.yml:13`) | — |
| Flutter SDK | app build/tests | ✓ | 3.44 (CLAUDE.md; 539 tests green per STATE.md) | — |
| Chrome or Edge with `chrome.bookmarks` | The whole feature | ✓ | Chromium ≥134 assumed for `folderType` (A2) | `roots[0]` index fallback |
| Node/JS test runner for `background.js` | Extension-side unit tests | ✗ | — | **No fallback in scope.** The repo has no JS test harness and adding one violates the no-new-packages posture. Extension logic is covered by (a) moving every testable rule to the server belt, and (b) the README console-paste smoke checks (`extension/README.md:44-65`, precedent A2–A5). |

**Missing dependencies with no fallback:** none blocking.
**Missing dependencies with fallback:** JS unit testing — see Validation Architecture, which relocates the coverage rather than adding a runner.

## Validation Architecture

### Test Framework

| Property | Value |
|---|---|
| Framework (Rust) | `cargo test` (workspace), stock `#[test]` / `#[tokio::test]` |
| Framework (Dart pkg) | `package:test` — `app/packages/remote_protocol` |
| Framework (Flutter app) | `flutter_test` — `app/remote_control` |
| Config files | `server/Cargo.toml` (workspace), `app/remote_control/pubspec.yaml`, `.github/workflows/ci.yml:13` |
| Quick run (Rust codec/fixtures) | `cd server && cargo test -p server-core codec_fixtures_bookmarks` |
| Quick run (Dart fixtures) | `cd app/packages/remote_protocol && dart test` (canonical cwd, enforced by `fixture_test.dart:24-31`) |
| Quick run (Flutter unit) | `cd app/remote_control && flutter test test/browser/` |
| Full suite | `cd server && cargo test --workspace` · `cd app/remote_control && flutter test` · `cd app/packages/remote_protocol && dart test` |

### Requirements → Test Map

| Decision | Behavior | Test Type | Layer & why that layer | Automated Command | Exists? |
|---|---|---|---|---|---|
| Wire | Rust↔Dart codec parity for the whole `bm.*` family | fixture | **Shared golden fixtures** — the only layer that can prove byte-identity across two languages; per-language copies are forbidden (SPEC §14) | `cargo test -p server-core codec_fixtures_bookmarks` + `dart test -N "bookmarks fixtures"` | ❌ Wave 0 |
| Wire | `TabEl.bookmarked` tri-state round-trips (true / false / absent) | fixture | Same; lands in the **existing** `tabs` family so no new harness fn is needed | `cargo test -p server-core codec_fixtures_tabs` | ❌ Wave 0 (fixture only) |
| Wire | Missing required `BmEl` field is a hard decode error | fixture (negative) | Fixture harnesses already branch on `expect.error == true` (`fixtures.rs:118-128`, `fixture_test.dart:128-135`) | same as above | ❌ Wave 0 |
| D-06 | `bm.state` → bookmarks watch, fields intact | integration (socket) | **`ext_relay.rs`** — SPEC §15 has no codec harness, so these socket tests *are* the ext-leg contract | `cargo test -p server-core --test ext_relay` | ❌ Wave 0 |
| D-06 | Server belt truncates >500 nodes | integration | `ext_relay.rs` — clone of `groups_belt_truncates_at_sixteen` (`:300-322`) | same | ❌ Wave 0 |
| D-06 | Malformed `nodes` degrades without discarding the frame | integration | `ext_relay.rs` — clone of `malformed_groups_degrade_to_empty` (`:327-346`) | same | ❌ Wave 0 |
| Pitfall 2 | Ext disconnect resets **BOTH** watches | integration | `ext_relay.rs` — the only layer where a real socket death is observable; clone of `ext_disconnect_resets_watch` (`:126-143`) and assert `BookmarksState::default()` too | same | ❌ Wave 0 |
| Wire | `ExtCmd::BmOpen/BmStar/BmUnstar/BmRemove` forward the right frames with the right payload keys | integration | `ext_relay.rs` — clone of `ext_cmd_forwards_activate_frame` (`:148-167`); this is what catches a `nodeId`/`tabId` swap | same | ❌ Wave 0 |
| §11 | `bm.open/star/unstar/remove` are dropped while paused | unit | **`router.rs` in-module tests** — extend `paused_drops_every_executor_bound_family_silently` (`:564`) with the four messages | `cargo test -p server-core paused_drops` | ❌ Wave 0 |
| §11 | `bm.list` is ANSWERED while paused | unit | `router.rs` — the read-exemption test alongside `tabs.list`/`apps.list`/`clip.get` (`:446`) | `cargo test -p server-core router` | ❌ Wave 0 |
| §11 | `bm.changed` from a client is silently ignored (no `unknownType`) | unit | `router.rs` — the S→C-only group (`:288-298`) | same | ❌ Wave 0 |
| Push | `bm.changed` is authed-gated (silence pre-auth, first push after auth) | integration | **`integration.rs`** — clone of `input_blocked_authed_gate_silence_then_single_push` (`:1158`); the T-06-01 privacy backstop | `cargo test -p server-core --test integration` | ❌ Wave 0 |
| Version | `SERVER_PROTO_VERSION == "1.6"` reaches the beacon and the `versionMismatch` reply | integration | `integration.rs:650` already asserts against the const; the beacon fixture pins the string | `cargo test --workspace` | ✅ (assertion exists; fixture value must be updated) |
| D-06/truncation | Node cap + byte loop | **manual + server belt** | The loop lives in `background.js` and the repo has **no JS test runner**. Coverage is relocated: the **server belt** (500-node truncation) is unit-tested in `ext_relay.rs`, and the extension-side loop is covered by a console-paste smoke check added to `extension/README.md` (precedent: checks A2–A5 at `:44-65`) plus UAT-3 | `cargo test --test ext_relay` + manual | ❌ Wave 0 |
| D-11 | Star renders filled / outline / absent for `true` / `false` / `null` | widget | **`browser_screen_test.dart`** — the only layer where "the star never misreports" is observable as a rendered glyph | `flutter test test/browser/browser_screen_test.dart` | ❌ Wave 0 |
| D-11 | Star tap does **not** activate the tab (nested-arena isolation, A6) | widget | Same — pins Pitfall 8 by observation, not reasoning: assert `onStar` once **and** zero `TabsActivateMsg` recorded | same | ❌ Wave 0 |
| D-11 | Star is inert when `!enabled` (gated-muted, never red) | widget | Same | same | ❌ Wave 0 |
| D-11 | Unstar is confirm-gated — a single tap sends nothing | widget | Same: tap the filled star ⇒ zero `BmUnstarMsg`; confirm ⇒ exactly one | same | ❌ Wave 0 |
| D-12 | Optimistic flip then reconcile | unit (store) | **`tabs_store_test.dart`** — a pure store test is deterministic (no timers, no widgets); the overlay must clear on **any** incoming snapshot, agreeing or not | `flutter test test/browser/tabs_store_test.dart` | ❌ Wave 0 (file exists) |
| D-14 | A folder with `count > 0` offers no delete; `count == 0` does | widget | `browser_screen_test.dart` — the affordance gate is a rendering rule. Chrome's `kFolderNotEmptyError` is the runtime backstop, unreachable from a widget test. | `flutter test test/browser/` | ❌ Wave 0 |
| D-01/D-02 | Segment swaps the list region; macro grid stays at the **same rect** across both segments | widget | `browser_screen_test.dart` — `tester.getRect()` on a macro button before and after the switch is the literal reading of D-02 | same | ❌ Wave 0 |
| D-03 | `bm.list` is NOT sent on screen open; IS sent on first Bookmarks switch; is NOT re-sent on a second switch | widget | Same — the fake service already records every `sendReliable` (`browser_screen_test.dart:100`) | same | ❌ Wave 0 |
| D-04 | Opening a bookmark leaves the segment and folder position unchanged | widget | Same | same | ❌ Wave 0 |
| D-05 | Drill-down + back stack over a flat node list | unit (store) | `bookmarks_store_test.dart` — pure navigation logic, no widgets needed | `flutter test test/browser/bookmarks_store_test.dart` | ❌ Wave 0 |
| D-05 | A deleted current folder self-heals to root | unit (store) | Same | same | ❌ Wave 0 |
| Regression | No new locked palette literal in `lib/` | guard | `test/theme_tokens_guard_test.dart` — already global over `lib/` | `flutter test test/theme_tokens_guard_test.dart` | ✅ |
| Regression | No classic `Icons.*` | guard | `test/icons_guard_test.dart` — already global | `flutter test test/icons_guard_test.dart` | ✅ |
| Regression | `removeTree` appears nowhere in `extension/` (D-14 structural) | guard | **New grep gate** — the cheapest possible enforcement of "a subtree wipe is structurally impossible" | a shell/CI grep step, or a Rust `#[test]` reading the file | ❌ Wave 0 |
| Regression | The 7-action macro vocabulary and existing tab-section behavior are untouched | widget | `browser_screen_test.dart:195-570` — 24 existing tests must stay green | `flutter test test/browser/` | ✅ |

### Sampling Rate

- **Per task commit:** the narrowest command for the layer touched — `cargo test -p server-core <filter>` / `flutter test test/browser/` / `dart test`.
- **Per wave merge:** `cd server && cargo test --workspace` **and** `cd app/remote_control && flutter test` **and** `cd app/packages/remote_protocol && dart test`. All three, because this phase edits all three trees and the fixture contract spans two of them.
- **Phase gate:** all three suites green + `flutter analyze` clean, then the on-device UAT below, then `/gsd-verify-work`.

### On-device UAT (human-verify, end-of-phase per config)

| # | Step | Pass criterion |
|---|---|---|
| **UAT-1** | **Permission reload (resolves A1).** Update `extension/manifest.json` in the loaded folder, press the reload arrow on `chrome://extensions`, and observe the extension's row. | Record what actually happens: (a) stays enabled — README says "press reload"; (b) shows a re-enable prompt — README gets the warning prose **and** the phone's install-hint copy is checked for adequacy. **Either outcome passes; an unrecorded outcome fails.** |
| UAT-2 | Bookmarks segment shows the roots (Bookmarks bar / Other / Mobile), drill into two levels, back out. | All roots present (D-08); position preserved on a push |
| UAT-3 | With a real bookmark collection, check the SW console snapshot log for the node count and byte size; confirm no `[tab-bridge] disconnected` follows a snapshot. | Frame under 56 KB; session survives (Pitfall 1) |
| UAT-4 | Open three bookmarks in a row from a nested folder. | Three new tabs; still in Bookmarks; still in the same folder (D-04) |
| UAT-5 | Star the active tab; confirm it lands in the **bookmarks bar** (not Other bookmarks). | D-10 — verify in Chrome's own bookmark manager |
| UAT-6 | Star a tab whose URL is bookmarked in two places; unstar via the confirm; check the bookmark manager. | **Both** entries gone (D-11); the confirm appeared |
| UAT-7 | Tap a star and immediately observe the row before the next push. | Flips instantly, stays flipped after the push (D-12) |
| UAT-8 | Try to delete a non-empty folder from the phone, then empty it and retry. | No delete offered while non-empty; delete works when empty (D-14) |
| UAT-9 | Close the browser entirely. | **Both** segments flip to the install hint (Pitfall 2) |
| UAT-10 | Pause input from the tray, then switch to Bookmarks and try to open one. | List still loads (`bm.list` read exemption); open does nothing (executor-bound) |
| UAT-11 | Regression sweep: tab activate / long-press close / swipe close / all 7 macros. | Byte-identical to pre-phase behavior |

### Wave 0 Gaps

- [ ] `protocol/fixtures/bookmarks/` — 8 fixture files (see §Wire Contract)
- [ ] `protocol/fixtures/tabs/09-tabs-changed-bookmarked.json` — tri-state `bookmarked`
- [ ] `server/server-core/tests/fixtures.rs` — `codec_fixtures_bookmarks()` registration (after `:184`)
- [ ] `app/packages/remote_protocol/test/fixture_test.dart` — `group('bookmarks fixtures')` registration (after `:202`)
- [ ] `server/server-core/tests/ext_relay.rs` — 5 new bm scenarios + a both-watch reset assertion
- [ ] `server/server-core/src/dispatch/router.rs` — extend the paused-drop and read-exemption tests
- [ ] `server/server-core/tests/integration.rs` — the authed-gate `bm.changed` scenario
- [ ] `app/remote_control/test/browser/bookmarks_store_test.dart` — NEW file (drill-down, back stack, self-heal)
- [ ] `app/remote_control/test/browser/tabs_store_test.dart` — extend with the D-12 optimistic overlay tests
- [ ] `app/remote_control/test/browser/browser_screen_test.dart` — extend with segment / D-02 rect / star / delete-gate tests
- [ ] A `removeTree` grep gate
- [ ] `extension/README.md` — a new console-paste smoke check for the bookmark snapshot (A6/A7, following the `:44-65` shape)
- [ ] Framework install: **none needed** — all three runners already exist

## Security Domain

**Config:** `security_enforcement: true`, `security_asvs_level: 1`, `security_block_on: high`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---|---|---|
| V2 Authentication | no (unchanged) | The `bm.*` family rides the existing challenge-response session (SPEC §4). No new auth surface. |
| V3 Session Management | no (unchanged) | No new session state; the ext leg's single-session newest-wins policy is untouched. |
| V4 Access Control | **yes** | Every `bm.*` message is post-auth only — enforced structurally, since `router.rs` is only reached after `AuthState::Authed` (SPEC §6, `session.rs:614`). The `bm.changed` push arm **must** carry the `== AuthState::Authed` guard (the `session.rs:331` clone) — omitting it leaks the owner's bookmark titles to an unauthenticated peer. |
| V5 Input Validation | **yes** | `nodeId` is an opaque string the server must never interpret. The extension must validate before acting: `bookmarks.get(nodeId)` result has a `url` before `tabs.create` (Pitfall 9), and every `remove` is `.catch()`-wrapped. The Rust codec's typed structs (`String` vs `i64`) are the wire-level validation. |
| V6 Cryptography | no | No new crypto. |
| V7 Error Handling & Logging | **yes** | **Bookmark titles and URLs are browsing data and must NEVER be logged** — the same rule as tab titles (`background.js:8-9`, `ext.rs:11-14`, SPEC §12 redaction-mandatory list). New log lines emit **counts and lifecycle only**. The `err` `msg` strings the server already produces are operator-facing prose that never embed ids (`router.rs:198-201` precedent) — and this phase adds **no new `err` codes** anyway (Pitfall 10). |
| V13 API & Web Service | **yes** | The ext leg's loopback bind IS the authentication boundary (SPEC §15) — unchanged. But see the residual escalation below. |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---|---|---|
| Bookmark titles/URLs leak into logs | Information Disclosure | Count-and-lifecycle-only logging; the existing snapshot log shape (`background.js:296-302`) |
| Bookmark titles pushed to an unauthenticated socket | Information Disclosure | `== AuthState::Authed` guard on the push arm (`session.rs:331` clone); a pre-auth-silence integration test |
| Oversize snapshot DoS / session kill | Denial of Service | `max_message_size` at `ext.rs:116-118` (already enforced) + the **byte-measured** extension budget loop (Pitfall 1) + the server's 500-node belt |
| **A local process destroys the owner's bookmarks** | **Tampering** | **NEW RESIDUAL — see below** |
| A local process feeds fake bookmark state | Spoofing | Already-accepted residual (SPEC §15: *"any LOCAL process can connect and feed fake tab state"*); extends to bookmark state with the same reasoning |
| Phone-driven subtree wipe with no undo | Tampering | D-14 structurally: `removeTree` never called; child-count affordance gate; Chrome's `kFolderNotEmptyError` backstop; grep gate |
| Managed/admin bookmark tampering | Tampering | `unmodifiable` → `locked: true` → affordance hidden; `kModifyManagedError` caught and ignored |
| Star deletes more than intended | Tampering | Exact-URL matching only — **no normalization** (§Star State); confirm gate before any delete (D-11/D-13) |

### Required SPEC §15 amendment (security-relevant, not just editorial)

SPEC §15 currently states the accepted residual as: *"any LOCAL process can connect and feed fake tab state or receive activate/close tab ids. A malicious local process already owns the machine."*

This phase **escalates that residual from read-and-close-tabs to write-and-delete-bookmarks** — the first ext-leg capability with a persistent, non-self-healing destructive effect (a closed tab can be reopened from history; a deleted bookmark cannot, and the phone has no undo, which is exactly why D-14 exists). The reasoning still holds (a local process that can open a loopback socket already owns the machine), but the SPEC prose must say so explicitly rather than leaving the reader with the old, narrower statement. **The planner should treat this §15 sentence as a required deliverable, not optional documentation.**

## Sources

### Primary (HIGH confidence — codebase, verified by direct read)
- `protocol/SPEC.md` §§1,2,7,11,13,14,15 — envelope, versioning, family registry, pause semantics, transport limits, fixtures, ext leg
- `extension/background.js` (349 lines) — snapshot builder, debounce, 56 KB loop, command handlers, listener registration
- `extension/manifest.json`, `extension/README.md` — permissions array, load-unpacked distribution, smoke-check precedent
- `server/server-core/src/transport/ext.rs` (240 lines) — relay loop, caps, watch reset sites
- `server/server-core/tests/ext_relay.rs` (362 lines) — the ext-leg contract tests
- `server/server-core/src/codec/json.rs` — `TabsListPayload`/`TabsChangedPayload`/`TabsActivatePayload`, additive-field pattern
- `server/server-core/src/executors/mod.rs` — `TabInfo`, `GroupInfo`, `TabsState`, `trait Tabs`, `Executors`
- `server/server-core/src/dispatch/router.rs` — read vs executor-bound classification, `is_executor_bound`, `browser_macro`
- `server/server-core/src/transport/session.rs` — `SERVER_PROTO_VERSION` (:60), authed-gated push arms (:203-346)
- `server/server-core/src/transport/mod.rs` — `ServerDeps`
- `server/server-windows/src/main.rs` — composition root, `run_ext` spawn (:392), `TabsRelay` (:177)
- `server/server-core/tests/fixtures.rs` — the Rust fixture harness (hard-registered families)
- `app/packages/remote_protocol/test/fixture_test.dart` — the Dart fixture harness (hard-registered families)
- `app/packages/remote_protocol/lib/src/json_codec.dart` — `TabInfo`/`GroupInfo`, `_tabList`/`_groupList`, tabs messages
- `app/packages/remote_protocol/lib/src/version.dart` — client `protoVersion`
- `app/remote_control/lib/browser/browser_screen.dart` (851 lines), `tabs_store.dart` (110 lines)
- `app/remote_control/lib/settings/settings_screen.dart:409-485` — hand-rolled segmented control
- `app/remote_control/lib/keyboard/key_pads.dart:184-271` — `KeyboardTabBar`; `key_rows.dart:279-319` — `KeyboardPadStore`
- `app/remote_control/lib/theme/tokens.dart`, `test/theme_tokens_guard_test.dart`, `test/icons_guard_test.dart`
- `app/remote_control/test/browser/browser_screen_test.dart` (678 lines)
- `protocol/fixtures/tabs/*.json`, `protocol/fixtures/beacon/01-valid.json`
- `.planning/STATE.md` "Roadmap Evolution" + Decisions log

### Primary (HIGH confidence — external, official source)
- [Chromium `bookmark_api_constants.cc`](https://chromium.googlesource.com/chromium/chromium/+/HEAD/chrome/browser/extensions/api/bookmarks/bookmark_api_constants.cc) — `kFolderNotEmptyError`, `kModifySpecialError`, `kModifyManagedError`, `kNoNodeError`, `kInvalidUrlError`
- [chrome.bookmarks API reference](https://developer.chrome.com/docs/extensions/reference/api/bookmarks) — `BookmarkTreeNode` fields, promise signatures, `search({url})` "matches verbatim", `remove()` empty-folder wording, root `"0"`, `folderType` enum, event descriptions incl. `onImportBegan`, deprecated write quotas
- [chrome.permissions API reference](https://developer.chrome.com/docs/extensions/reference/api/permissions) — `request()` requires a user gesture
- [Permission warning guidelines](https://developer.chrome.com/docs/extensions/develop/concepts/permission-warnings) — *"When a new permission that triggers a warning is added, the extension will be disabled until the user accepts the new permission."*
- [Permissions list](https://developer.chrome.com/docs/extensions/reference/permissions-list) — `bookmarks` ⇒ "Read and change your bookmarks"
- [Service worker events](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/events) — top-level synchronous listener registration

### Secondary (MEDIUM confidence)
- [Declare permissions and warn users (MV2)](https://developer.chrome.com/docs/extensions/mv2/permission-warnings) — *"No permission warnings will be displayed if an extension is loaded as an unpacked file"* and the `optional_permissions` circumvention. Official but MV2-era; the basis for A1 and for UAT-1.
- [MDN bookmarks.remove()](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/bookmarks/remove) — corroborates the non-empty-folder rejection for the shared WebExtensions API shape

### Tertiary (LOW confidence — used only for corroboration, never as sole basis)
- WebSearch summaries on unpacked-extension reload behavior — consistent with the MV2 doc, but blog-tier; A1 remains gated on UAT-1

### Measurements taken in this session
- Per-node JSON byte costs and the flat-vs-nested comparison were **computed locally** with `node -e` `Buffer.byteLength(JSON.stringify(...))` against the exact candidate node shapes. Figures in §Payload Budget Math are measured, not estimated.

## Metadata

**Confidence breakdown:**
- Wire contract & version machinery: **HIGH** — every site verified by grep + read; the "SERVER_PROTO_VERSION lives in codec/json.rs" note in CONTEXT.md was checked and corrected
- Standard stack: **HIGH** — zero new packages; every API is either a documented browser built-in or an existing direct dependency
- Payload budget math: **HIGH** — byte counts measured locally against real serialized shapes, not estimated
- Architecture patterns: **HIGH** — every pattern cited to a shipped file:line with a named precedent
- Pitfalls: **HIGH** for 1–7 and 9–10 (each traced to a specific line or a documented Chrome error); **MEDIUM** for 8 (Flutter arena behavior — deliberately converted into a required test rather than a claim)
- Chrome bookmarks API surface: **HIGH** — official reference + Chromium source for the error strings
- Permission re-approval behavior: **MEDIUM** — see A1; resolved by UAT-1, not by more reading
- `getTree()` latency on a large profile: **LOW / UNVERIFIED** — see A3

**Research date:** 2026-07-29
**Valid until:** 2026-08-28 (30 days — Chrome's bookmarks API is a decade-stable surface; the only fast-moving item is the `folderType`/`syncing` availability floor, already past)
