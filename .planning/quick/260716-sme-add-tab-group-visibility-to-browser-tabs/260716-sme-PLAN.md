---
quick_id: 260716-sme
type: quick
autonomous: true
files_modified:
  - extension/manifest.json
  - extension/background.js
  - protocol/SPEC.md
  - protocol/fixtures/tabs/06-tabs-changed-with-groups.json
  - protocol/fixtures/tabs/07-tabs-list-reply-with-groups.json
  - protocol/fixtures/tabs/08-tabs-group-missing-color.json
  - protocol/fixtures/beacon/01-valid.json
  - server/server-core/src/executors/mod.rs
  - server/server-core/src/executors/mock.rs
  - server/server-core/src/codec/json.rs
  - server/server-core/src/transport/ext.rs
  - server/server-core/src/transport/session.rs
  - server/server-core/src/dispatch/router.rs
  - server/server-core/tests/ext_relay.rs
  - server/server-core/tests/integration.rs
  - app/packages/remote_protocol/lib/src/json_codec.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/lib/browser/tabs_store.dart
  - app/remote_control/lib/browser/browser_screen.dart
  - app/remote_control/test/browser/tabs_store_test.dart
  - app/remote_control/test/browser/browser_screen_test.dart
requirements: [BROW-01]
must_haves:
  truths:
    - "The extension reports tab groups (id, title, color name, collapsed) plus each grouped tab's groupId in every tabs.state snapshot; ungrouped tabs carry NO groupId key"
    - "A 1.4-shape tabs.changed / tabs.list frame WITHOUT groups (and with groupId-less TabEls) still decodes in BOTH codecs — fixtures 01–05 stay byte-untouched and green (additive 1.4 → 1.5)"
    - "The phone's Browser screen renders grouped tab rows under a group header tinted with the Chrome group color; ungrouped tabs render exactly as today (flat rows, no header)"
    - "A collapsed group renders as display metadata only (dimmed header); the phone has NO way to create/collapse/move groups — no new C→S message types exist"
    - "tabs.activate / tabs.close semantics are byte-untouched; group titles never appear in any extension console log or server log sink"
    - "Group caps hold the 56 KB frame budget: max 16 groups, group titles truncated to 32 chars extension-side; the server belts groups at 16 like it belts tabs at 50"
  artifacts:
    - path: "protocol/SPEC.md"
      provides: "protoVersion 1.5 header + §2 amendment note, GroupEl definition, groups field on tabs.list/tabs.changed (§7) and tabs.state (§15), group caps in §15 limits"
      contains: "GroupEl"
    - path: "protocol/fixtures/tabs/06-tabs-changed-with-groups.json"
      provides: "Golden round-trip: tabs.changed with groups array + grouped/ungrouped TabEls + unknown-field drop inside a GroupEl"
      contains: "groups"
    - path: "protocol/fixtures/tabs/08-tabs-group-missing-color.json"
      provides: "Negative fixture: GroupEl missing required color is a hard decode error in both codecs"
      contains: "\"error\": true"
    - path: "server/server-core/src/executors/mod.rs"
      provides: "GroupInfo struct next to TabInfo; TabsState.groups; TabInfo.group_id (wire: groupId)"
      contains: "GroupInfo"
    - path: "app/packages/remote_protocol/lib/src/json_codec.dart"
      provides: "Dart GroupInfo + TabInfo.groupId + groups on TabsListMsg/TabsChangedMsg"
      contains: "GroupInfo"
    - path: "app/remote_control/lib/browser/browser_screen.dart"
      provides: "Group headers (color dot + tinted title, collapsed dimming) over consecutive grouped-tab runs; Chrome color-name → Color map"
      contains: "kGroupColors"
  key_links:
    - from: "extension/background.js"
      to: "server/server-core/src/transport/ext.rs"
      via: "tabs.state payload gains groups array + per-tab groupId"
      pattern: "chrome\\.tabGroups"
    - from: "server/server-core/src/transport/ext.rs"
      to: "server/server-core/src/transport/session.rs"
      via: "TabsState.groups through the watch channel into tabs_changed_frame"
      pattern: "groups"
    - from: "app/remote_control/lib/net/connection_service.dart"
      to: "app/remote_control/lib/browser/tabs_store.dart"
      via: "TabsSnapshot.groups re-snapshotted into TabsViewState.groups"
      pattern: "groups"
    - from: "app/remote_control/lib/browser/tabs_store.dart"
      to: "app/remote_control/lib/browser/browser_screen.dart"
      via: "TabsViewState.groups drives _TabsSection group headers"
      pattern: "tabsStateProvider"
---

<objective>
Add tab-group VISIBILITY to the browser tabs feature (260716-oi2 follow-on,
BROW-01): the Chrome extension reports tab groups (id, title, color,
collapsed) and each tab's groupId in `tabs.state` snapshots; the protocol
bumps additively 1.4 → 1.5 with `groups` on `tabs.state`/`tabs.list`/
`tabs.changed` plus golden fixtures; the server relays groups through
TabInfo/TabsState and the codec; the Flutter Browser screen renders tab rows
under group headers tinted with the Chrome group color.

Strictly VIEW-ONLY: no group create/collapse/move commands, no new C→S
message types, tabs.activate/tabs.close untouched.

Purpose: the phone's tab list currently flattens grouped tabs into an
undifferentiated pile — group headers restore the PC-side visual structure.
Output: extension 1.1 behavior + SPEC 1.5 + 3 new fixtures + Rust relay
plumbing + Dart codec + grouped Browser-screen rendering, all suites green.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@.planning/quick/260716-oi2-browser-tab-list-and-switching-via-chrom/260716-oi2-SUMMARY.md
@protocol/SPEC.md
@extension/background.js
@extension/manifest.json
@server/server-core/src/executors/mod.rs
@server/server-core/src/codec/json.rs
@server/server-core/src/transport/ext.rs
@server/server-core/src/transport/session.rs
@server/server-core/src/dispatch/router.rs
@app/packages/remote_protocol/lib/src/json_codec.dart
@app/remote_control/lib/net/connection_service.dart
@app/remote_control/lib/browser/tabs_store.dart
@app/remote_control/lib/browser/browser_screen.dart
</context>

## Locked wire contract (all three tasks implement EXACTLY this)

**GroupEl (new, protoVersion 1.5):**
`{id: integer, title: string, color: string, collapsed: bool}` — ALL four
fields required within an element (missing → hard decode error, like TabEl's
id/title/active). `color` is Chrome's NAMED color string passed through
verbatim (`grey|blue|red|yellow|green|pink|purple|cyan|orange`) — the
extension never invents hex; the phone maps name → Color. `title` may be
empty (Chrome allows unnamed groups); capped at 32 chars extension-side.

**TabEl amendment:** gains optional `groupId` (integer). Absent = ungrouped
(the extension OMITS the key when `tab.groupId === -1`, i.e.
`chrome.tabGroups.TAB_GROUP_ID_NONE`) — the WindowInfo `icon`/`path`
skip-when-absent convention, never emitted as null.

**Payload amendments (all additive/optional):** `tabs.state` (ext→srv, §15),
the `tabs.list` reply, and `tabs.changed` each gain `groups` (array of
GroupEl). Absent `groups` = a 1.4 peer and MUST decode (both codecs model it
as an Option/nullable — absent stays absent on canonical re-encode; present,
including `[]`, round-trips). The 1.5 server always emits `groups` in its own
tabs.list replies and tabs.changed pushes.

**Caps (56 KB frame-budget discipline):** max **16 groups** per snapshot,
group `title` truncated to **32 chars** extension-side; the server
additionally truncates groups at 16 (the MAX_EXT_TABS belt pattern). The
existing icon-strip fallback loop keeps working unchanged (groups add ≤ ~1.5
KB worst case).

**Version:** SPEC header + §2 → `"1.5"`; `SERVER_PROTO_VERSION` → `"1.5"`;
`protocol/fixtures/beacon/01-valid.json` proto → `"1.5"` in BOTH `wire` and
`expect` (the D-09 lockstep from 06-01). The Dart client's `protoVersion`
const in `app/packages/remote_protocol/lib/src/version.dart` stays `'1.1'`
UNTOUCHED — precedent from 260716-oi2 (minor mismatch is accepted; the const
is what the client advertises, not what it understands).

<tasks>

<task type="auto">
  <name>Task 1: Extension group reporting + SPEC 1.5 + golden fixtures</name>
  <files>extension/manifest.json, extension/background.js, protocol/SPEC.md, protocol/fixtures/tabs/06-tabs-changed-with-groups.json, protocol/fixtures/tabs/07-tabs-list-reply-with-groups.json, protocol/fixtures/tabs/08-tabs-group-missing-color.json, protocol/fixtures/beacon/01-valid.json</files>
  <action>
**extension/manifest.json:** add `"tabGroups"` to `permissions` (alongside
tabs/favicon/alarms); bump `"version"` to `"1.1.0"`. `tabGroups` carries no
new install warning (the scary "read browsing history" one is already there
from `tabs`).

**extension/background.js:**
1. New consts next to the existing caps: `MAX_GROUPS = 16`,
   `MAX_GROUP_TITLE = 32` (comment: must stay in sync with SPEC §15).
2. Group events feed the SAME debounced snapshot: register
   `chrome.tabGroups.onCreated/onUpdated/onRemoved/onMoved` listeners calling
   the existing `onTabEvent` (guard the whole registration block with
   `if (chrome.tabGroups)` so the worker still loads on a browser without the
   API).
3. In `buildAndSend()`, after the tabs query: query
   `chrome.tabGroups.query({})` in its own try/catch — on ANY failure (API
   absent, transient error) degrade to `groups = []` and still send the
   snapshot. Build GroupEls `{id, title: (g.title || "").slice(0, MAX_GROUP_TITLE),
   color: g.color, collapsed: !!g.collapsed}`. Filter to group ids actually
   referenced by the tabs being sent (a group whose tabs all fell past the
   50-tab cap is dead weight), then `slice(0, MAX_GROUPS)`.
4. Per-tab: add `groupId` to the TabEl ONLY when
   `tab.groupId !== undefined && tab.groupId !== NONE` where
   `const NONE = chrome.tabGroups ? chrome.tabGroups.TAB_GROUP_ID_NONE : -1`
   (module-level const). Never emit `groupId: -1`.
5. Frame becomes `{t: "tabs.state", p: {tabs: els, groups}}` — ALWAYS include
   `groups` (empty array when none; the ext leg has one implementation each
   side, no need for absent-key parsimony here). The 56 KB icon-strip loop is
   unchanged except each re-serialize includes `groups` (it already
   re-stringifies the whole frame — just add groups to both stringify calls).
6. Privacy discipline (existing rule extended): NEVER log group titles —
   counts only. The existing "snapshot sent: N tabs" log may append the group
   count.

**protocol/SPEC.md:**
1. Header line 3: protoVersion `"1.4"` → `"1.5"`. §2 line "Current version"
   → `"1.5"`. Add a §2 amendment bullet after the 1.4 one:
   `**1.5 addition (BROW-01):** tab-group visibility — the GroupEl element,
   optional groups on the tabs.list reply / tabs.changed / tabs.state
   payloads, and the optional TabEl groupId. View-only (no group commands).
   Minor bump — 1.0–1.4 clients stay accepted.`
2. §7 `tabs.list` row: reply optional fields gain `groups` (array of GroupEl,
   1.5 — absent from 1.4 servers). §7 `tabs.changed` row: same optional
   `groups` addition.
3. Below the TabEl definition (§7, line ~133): amend TabEl with
   `groupId?` (integer, 1.5 — absent = ungrouped, never null) and add the
   GroupEl definition paragraph: the four required fields, the named-color
   vocabulary `grey|blue|red|yellow|green|pink|purple|cyan|orange`
   (pass-through — unknown names render as a neutral fallback client-side),
   title-may-be-empty, and "collapsed is display metadata only — no wire
   message toggles it".
4. §15: `tabs.state` row `p` becomes `tabs` (array of TabEl) + `groups`
   (array of GroupEl, optional). Limits paragraph gains: max 16 groups, group
   titles capped at 32 chars extension-side; server belts groups at 16.

**Fixtures** (family `tabs` is ALREADY hard-registered in both harnesses and
both `run_json_family` implementations enumerate every file in the directory
— new files need NO test-fn registration; verified against
server-core/tests/fixtures.rs:95 and remote_protocol/test/fixture_test.dart:104):
- `06-tabs-changed-with-groups.json`: wire `tabs.changed`
  `{connected:true, groups:[{id:1, title:"Work", color:"blue",
  collapsed:false, future:"ignored"}, {id:2, title:"", color:"orange",
  collapsed:true}], tabs:[{id:7, title:"GitHub", active:true, groupId:1},
  {id:9, title:"Docs", active:false}]}`; expect = same minus the `future`
  key. Proves: groups round-trip, D-05 unknown-field drop INSIDE a GroupEl,
  grouped tab keeps groupId, ungrouped tab re-encodes WITHOUT the key, empty
  title + collapsed:true round-trip.
- `07-tabs-list-reply-with-groups.json`: wire `tabs.list` reply
  `{connected:true, groups:[{id:4, title:"News", color:"green",
  collapsed:false}], tabs:[{id:3, title:"BBC", active:true, groupId:4}]}`;
  expect identical. Proves the reply-shape groups round-trip.
- `08-tabs-group-missing-color.json`: wire `tabs.changed` with
  `groups:[{id:1, title:"Work", collapsed:false}]` (color missing) and a
  minimal valid tabs array; `"expect": {"error": true}` with a description
  noting GroupEl's four required fields — follow fixture 04's negative
  format exactly.
- Follow the existing fixture style: `name`, `description` (cite
  "protocol 1.5" + this quick id), `wire`, `expect`. Fixtures 01–05 stay
  byte-untouched (they ARE the 1.4-compat regression).

**protocol/fixtures/beacon/01-valid.json:** `"proto": "1.4"` → `"1.5"` in
both `wire` and `expect` (lockstep with SERVER_PROTO_VERSION, which Task 2
bumps — the beacon fixture harness compares against the const).
  </action>
  <verify>
    <automated>node --check extension/background.js && python -m json.tool extension/manifest.json > NUL && python -m json.tool protocol/fixtures/tabs/06-tabs-changed-with-groups.json > NUL && python -m json.tool protocol/fixtures/tabs/07-tabs-list-reply-with-groups.json > NUL && python -m json.tool protocol/fixtures/tabs/08-tabs-group-missing-color.json > NUL</automated>
  </verify>
  <done>manifest has tabGroups permission; background.js sends groups + per-tab groupId under the caps with the icon-strip loop intact; SPEC.md reads 1.5 with GroupEl + groups + §15 caps; 3 new fixtures parse as JSON; beacon fixture says 1.5. KNOWN-RED CHECKPOINT: `cargo test -p server-core --test fixtures` and the Dart fixture suite are EXPECTED to fail on fixtures 06/07 (current codecs drop the unknown `groups` field on re-encode) and on the beacon version until Tasks 2–3 land — do not "fix" the fixtures to make them pass.</done>
</task>

<task type="auto">
  <name>Task 2: Rust server — GroupInfo through codec, relay, session, router</name>
  <files>server/server-core/src/executors/mod.rs, server/server-core/src/executors/mock.rs, server/server-core/src/codec/json.rs, server/server-core/src/transport/ext.rs, server/server-core/src/transport/session.rs, server/server-core/src/dispatch/router.rs, server/server-core/tests/ext_relay.rs, server/server-core/tests/integration.rs</files>
  <action>
**executors/mod.rs:**
1. New `GroupInfo` struct directly above `TabsState` (trait-returned types
   live with the traits — the TabInfo precedent):
   `pub struct GroupInfo { pub id: i64, pub title: String, pub color: String,
   pub collapsed: bool }` deriving exactly what TabInfo derives
   (`Debug, Clone, PartialEq, Eq, Serialize, Deserialize`). Doc comment: all
   four fields wire-required; `color` is the Chrome named-color string
   (SPEC §7 GroupEl) — the server passes it through, never validates the
   vocabulary (codec stays value-lenient, the Phase-01 enum-string rule).
2. `TabInfo` gains
   `#[serde(rename = "groupId", default, skip_serializing_if = "Option::is_none")]
   pub group_id: Option<i64>,` — absent = ungrouped, never null (WindowInfo
   icon/path convention). `Eq` derive survives (i64 is Eq).
3. `TabsState` gains `pub groups: Vec<GroupInfo>,` — `Default` still derives
   (never-connected shape is now `{connected:false, tabs:[], groups:[]}`).

**codec/json.rs:**
1. `TabsListPayload` gains
   `#[serde(default, skip_serializing_if = "Option::is_none")]
   pub groups: Option<Vec<GroupInfo>>,` (the existing Option-fields style of
   that struct).
2. `TabsChangedPayload` gains the SAME optional `groups` field — doc comment:
   unlike `connected`/`tabs` (required), `groups` is optional because a 1.4
   frame without it must decode (additive 1.5); absent stays absent on
   canonical re-encode, present (including `[]`) round-trips.
3. Import `GroupInfo` where `TabInfo` is imported. No new Msg variants, no
   new decode/encode arms — the four existing tabs.* arms are untouched.

**transport/ext.rs:** in `handle_ext_text`'s `"tabs.state"` arm, also parse
`frame.p.get("groups")`: `serde_json::from_value::<Vec<GroupInfo>>(...)
.unwrap_or_default()` (tolerant — a malformed groups array degrades to empty,
it does NOT discard the whole frame; the tabs parse keeps its existing
stricter behavior). Add `const MAX_EXT_GROUPS: usize = 16;` next to
`MAX_EXT_TABS` and `groups.truncate(MAX_EXT_GROUPS)`. Send
`TabsState { connected: true, tabs, groups }`.

**transport/session.rs:** `SERVER_PROTO_VERSION` `"1.4"` → `"1.5"` (update
the doc comment). `tabs_changed_frame` maps the new field:
`groups: Some(state.groups)` — the 1.5 server ALWAYS emits groups in its
pushes (empty array when none; old clients ignore the unknown key per D-05).

**dispatch/router.rs:** the `Msg::TabsList(_)` reply arm adds
`groups: Some(state.groups)`. In the test module, `PopulatedTabs::state()`
gains a non-empty `groups` vec (one GroupInfo, e.g.
`{id: 1, title: "Work", color: "blue", collapsed: false}`) and tab id 7 gains
`group_id: Some(1)`; extend `paused_tabs_list_still_answers_with_state` to
assert the reply carries `groups == Some(vec![...])` (or len 1 + field spot
checks).

**Compile-fix sweep:** every `TabsState { ... }` struct literal and every
`TabInfo { ... }` literal in src + tests now needs the new field — known
sites: router.rs tests (PopulatedTabs), executors/mock.rs (if it constructs
either type rather than returning `TabsState::default()`), tests/ext_relay.rs,
tests/integration.rs (the tabs push/preauth tests), and any
`TabsListPayload`/`TabsChangedPayload` literal (add `groups: None` where the
test means a 1.4-shape frame, or a real value where groups are under test).
Prefer adding explicit fields over `..Default::default()` in test literals so
assertions stay visibly exhaustive.

**New test coverage (extend existing files, no new harnesses):**
1. tests/ext_relay.rs: one scenario feeding a `tabs.state` frame WITH groups
   + per-tab groupId through a real ext socket, asserting the watch snapshot
   carries the groups and the groupId; feed 17+ groups and assert truncation
   to 16; feed a frame with `"groups": "garbage"` and assert tabs still land
   with `groups == []` (tolerant-degrade).
2. tests/integration.rs: whichever existing test asserts the hello/version
   string must now expect `"1.5"` (grep for `1.4` literals in tests and bump
   ONLY the ones pinning SERVER_PROTO_VERSION/beacon proto — fixture-family
   comments citing "protocol 1.4" history stay).
3. The fixture harness needs NO change — fixtures 06/07/08 are picked up
   automatically and must now pass (06/07 round-trip through the new
   Option groups; 08 fails decode because GroupInfo.color is required —
   serde maps it to the existing missing-field error path fixture 04 uses).
  </action>
  <verify>
    <automated>cd server && cargo test -p server-core</automated>
  </verify>
  <done>cargo test -p server-core fully green (unit + ext_relay + fixtures incl. 06/07/08 + beacon at 1.5 + integration); GroupInfo flows extension-frame → watch → tabs.changed push and tabs.list reply; 1.4-shape frames without groups still decode (fixtures 01–05 untouched and green); groups belt-truncated at 16.</done>
</task>

<task type="auto">
  <name>Task 3: Dart codec + Flutter grouped tab rendering</name>
  <files>app/packages/remote_protocol/lib/src/json_codec.dart, app/remote_control/lib/net/connection_service.dart, app/remote_control/lib/browser/tabs_store.dart, app/remote_control/lib/browser/browser_screen.dart, app/remote_control/test/browser/tabs_store_test.dart, app/remote_control/test/browser/browser_screen_test.dart</files>
  <action>
**remote_protocol json_codec.dart** (exported via the existing
`export 'src/json_codec.dart'` barrel line — no barrel change needed):
1. New `GroupInfo` class next to `TabInfo` (same shape discipline): final
   `int id`, `String title`, `String color`, `bool collapsed`; const ctor;
   `toJson()` emitting all four keys; value `==`/`hashCode`. Doc comment:
   protoVersion 1.5, color is the Chrome named string — map to a Color in the
   app layer, unknown names fall back neutrally.
2. `TabInfo` gains `final int? groupId` (const ctor param, optional):
   `toJson()` adds `if (groupId != null) 'groupId': groupId`; extend
   `==`/`hashCode`. `_tabList` parses `groupId: _opt<int>(e, 'groupId')`.
3. New `_groupList(Object? v, String key)` parser mirroring `_tabList`:
   throws FormatException unless a List of objects; each element requires
   id/title/color/collapsed via `_req` (missing → hard decode error, fixture
   08), unknown extra fields ignored.
4. `TabsListMsg` gains `final List<GroupInfo>? groups` — fromPayload:
   `final rawGroups = p['groups']; groups: rawGroups == null ? null :
   _groupList(rawGroups, 'groups')` (the existing raw-tabs pattern);
   toPayload adds `if (groups != null) 'groups': groups!.map((e) =>
   e.toJson()).toList()`. `TabsChangedMsg` gains the IDENTICAL optional
   groups treatment (connected/tabs stay required). Canonical rule matches
   Rust: absent stays absent, present (even empty) round-trips — this is what
   makes fixtures 06/07 pass and 01–05 keep passing.

**connection_service.dart:** `TabsSnapshot` gains
`final List<GroupInfo> groups` (required ctor param; hand-rolled element-wise
`==` extended, hashCode via `Object.hash(connected, Object.hashAll(tabs),
Object.hashAll(groups))` — the 06-03 no-package:collection rule). Parking
sites: `TabsChangedMsg` arm passes `groups: msg.groups ?? const []`;
`TabsListMsg` arm passes `groups: msg.groups ?? const []`. No payload logging
(group titles are browsing data — same rule as tab titles).

**tabs_store.dart:** `TabsViewState` gains `final List<GroupInfo> groups`
(extend `==`/`hashCode` element-wise). `_view()` maps
`groups: snapshot?.groups ?? const []`. Commands untouched (view-only).

**browser_screen.dart:**
1. Module-level `const Map<String, Color> kGroupColors` — Chrome dark-theme
   group palette (readable on kBg #0E0F12): grey `#8E918F`, blue `#8AB4F8`,
   red `#F28B82`, yellow `#FDD663`, green `#81C995`, pink `#FF8BCB`, purple
   `#C58AF9`, cyan `#78D9EC`, orange `#FCAD70`. Lookup helper returns kMuted
   for unknown names. NOTE: these are NEW local color consts, NOT theme
   tokens — the D-12 guard test only bans the 7 locked token literals
   (connection_header precedent), so do NOT touch theme/tokens.dart.
2. `_TabsSection` build: keep extension order, NO client re-sort. Walk the
   tab list; when a tab's `groupId` resolves to a known GroupInfo (build a
   `{id: GroupInfo}` map once) AND differs from the previous tab's groupId,
   insert a `_GroupHeader` row before it. Tabs whose groupId is null or
   unresolved (group fell past the cap) render flat exactly as today —
   byte-identical row widget, no inset change. Chrome keeps a group's tabs
   contiguous in the strip, so consecutive-run detection is correct; a
   non-contiguous edge case would just repeat the header (harmless, no
   dedupe machinery).
3. `_GroupHeader` (new private widget): 8px color dot (the mapped group
   color) + group title at 12/600 tinted with the SAME mapped color; empty
   title renders the dot alone. Collapsed groups: wrap the header content in
   `Opacity(0.5)` and append a small muted `Symbols.unfold_less_rounded`
   glyph — display metadata ONLY, no gesture handlers anywhere on the header
   (view-only is structural: the header widget has no callbacks). Grouped
   tab rows themselves render at full strength (the PC may show them
   collapsed; the phone lists them — accepted, documented in the widget doc
   comment).
4. Update the library/section doc comments to mention groups + proto 1.5 +
   this quick id.

**version.dart is NOT touched** — the client-advertised `protoVersion` const
stays `'1.1'` (260716-oi2 precedent; minor mismatch accepted §2).

**Tests:**
1. tabs_store_test.dart: TabsViewState equality includes groups (two states
   differing only in a group's collapsed flag are unequal); notifier maps a
   parked snapshot's groups through to the view; a snapshot with
   `groups: []` yields the flat view.
2. browser_screen_test.dart: pump a TabsViewState with one group (blue,
   "Work") owning two tabs + one ungrouped tab → expect exactly one group
   header (find the "Work" text, assert its color == kGroupColors['blue']),
   ungrouped tab row has NO header above it; collapsed group header renders
   inside an Opacity(0.5); header has no tap handlers (tap it, assert no
   activate/close callback fired); all existing 09-04 + 260716-oi2 pinned
   assertions stay green.
3. The remote_protocol fixture harness picks up fixtures 06/07/08
   automatically (`tabs fixtures` group already registered) — must go green
   with zero test-file edits.
  </action>
  <verify>
    <automated>cd app/packages/remote_protocol && dart test && cd ../../remote_control && flutter analyze && flutter test</automated>
  </verify>
  <done>dart test (remote_protocol) green including the tabs fixture family with 06/07/08; flutter analyze clean; flutter test fully green; Browser screen shows group headers tinted per Chrome color with collapsed dimming, ungrouped tabs unchanged; no new C→S messages exist anywhere in the diff.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| extension → server ext leg | Localhost-only WS (SPEC §15); any LOCAL process can feed fake group data — accepted v1 residual (unchanged) |
| server → phone | tabs.changed/tabs.list now carry group titles — browsing data, same sensitivity class as tab titles |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-SME-01 | Information Disclosure | session.rs tabs push | mitigate | Group titles ride the EXISTING authed-gated tabs.changed branch only — no new push site is created; the auth gate is inherited by construction |
| T-SME-02 | Information Disclosure | extension/background.js, connection_service.dart | mitigate | Never log group titles (extension console + server sinks + Flutter) — counts only, same rule as tab titles (T-01-31) |
| T-SME-03 | Denial of Service | ext.rs tabs.state handler | mitigate | MAX_EXT_GROUPS=16 server belt + extension-side 16-group/32-char caps; the 64 KB per-listener WS cap already kills oversize frames |
| T-SME-04 | Tampering | ext leg (fake groups from a local process) | accept | Unchanged §15 residual: a malicious local process already owns the machine; groups add no new capability (view-only) |
| T-SME-SC | Tampering | package installs | accept | Zero new dependencies in any of the three ecosystems (vanilla JS, existing crates, existing pub packages) |
</threat_model>

<verification>
1. `cd server && cargo test -p server-core` — all green (fixtures 01–08, beacon at 1.5, ext_relay group scenarios, integration).
2. `cd app/packages/remote_protocol && dart test` — all green (same shared fixtures).
3. `cd app/remote_control && flutter analyze && flutter test` — clean + green.
4. `node --check extension/background.js` — syntax-valid service worker.
5. Grep gates: `grep -rn "tabs.group" server app` returns nothing (no invented command family); fixtures 01–05 byte-identical to git HEAD (`git diff --stat protocol/fixtures/tabs/0[1-5]*` empty).
</verification>

<success_criteria>
- Protocol 1.5 is additive: both codecs decode 1.4-shape tabs frames (no groups, no groupId) AND round-trip 1.5 frames with groups, proven by shared golden fixtures in both harnesses.
- Extension reports groups + groupId under the 16-group/32-char/56 KB caps with the icon-strip fallback intact.
- Server relays groups end-to-end (ext socket → watch → authed push / list reply) with the 16-group belt.
- Browser screen renders group headers tinted with the mapped Chrome color, collapsed shown as dimmed display metadata, ungrouped tabs byte-identical to today.
- View-only holds structurally: zero new C→S message types, tabs.activate/close untouched, group header widget has no callbacks.
- All three suites green: cargo test -p server-core, dart test (remote_protocol), flutter analyze + flutter test.
</success_criteria>

<output>
Create `.planning/quick/260716-sme-add-tab-group-visibility-to-browser-tabs/260716-sme-SUMMARY.md` when done.
</output>
