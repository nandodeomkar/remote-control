---
quick_id: 260716-sme
type: quick
status: complete
requirements: [BROW-01]
subsystem: browser-tabs
tags: [extension, mv3, protocol-1.5, tab-groups, flutter-ui]
commits:
  - 24aa794
  - 5b55d6f
  - a08d992
key-files:
  created:
    - protocol/fixtures/tabs/06-tabs-changed-with-groups.json
    - protocol/fixtures/tabs/07-tabs-list-reply-with-groups.json
    - protocol/fixtures/tabs/08-tabs-group-missing-color.json
  modified:
    - extension/manifest.json (tabGroups permission, version 1.1.0)
    - extension/background.js
    - protocol/SPEC.md (1.4 → 1.5)
    - protocol/fixtures/beacon/01-valid.json
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/codec/json.rs
    - server/server-core/src/transport/{ext,session}.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/tests/{ext_relay,integration}.rs
    - app/packages/remote_protocol/lib/src/json_codec.dart
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/browser/{tabs_store,browser_screen}.dart
    - app/remote_control/test/browser/{tabs_store_test,browser_screen_test}.dart
completed: 2026-07-16
---

# Quick Task 260716-sme: Tab-Group Visibility — Summary

**One-liner:** The phone's Browser tab list now shows Chrome tab groups —
view-only group headers (color dot + title tinted with the Chrome group
color, collapsed shown dimmed) over consecutive grouped-tab runs — fed by an
additive protoVersion 1.5 `groups`/`groupId` amendment flowing extension →
server relay → phone.

## What Was Built (all 3 tasks, executed inline — no executor subagent, user-directed)

### Task 1 — Extension + SPEC 1.5 + fixtures (24aa794)
- manifest: `tabGroups` permission, version 1.1.0 (no new install warning).
- background.js: `chrome.tabGroups.onCreated/onUpdated/onRemoved/onMoved` →
  same debounced snapshot (whole block guarded on API presence);
  `buildAndSend` queries groups in its own try/catch (ANY failure degrades
  to `[]`, snapshot still sends); GroupEls capped at 16 groups / 32-char
  titles, filtered to groups actually referenced by the ≤50 tabs sent;
  per-tab `groupId` emitted ONLY when grouped (never `-1`, never null);
  `groups` always present in the frame; icon-strip 56 KB loop intact; group
  titles never logged (counts only).
- SPEC.md: header + §2 → 1.5 with amendment bullet; §7 GroupEl definition
  (4 required fields, named-color vocabulary pass-through, title-may-be-empty,
  collapsed = display metadata) + TabEl `groupId?`; §7 tabs.list/tabs.changed
  optional `groups`; §15 tabs.state `groups` + 16-group/32-char caps.
- Fixtures 06 (groups round-trip + D-05 unknown-field drop inside GroupEl +
  ungrouped-tab key omission), 07 (list-reply shape), 08 (negative: missing
  color = hard decode error). Beacon fixture 1.4 → 1.5 in lockstep.

### Task 2 — Rust server relay (5b55d6f)
- executors/mod.rs: `GroupInfo` (Debug/Clone/PartialEq/Eq/Serialize/
  Deserialize — TabInfo parity); `TabInfo.group_id` (`rename="groupId"`,
  skip-when-None); `TabsState.groups` (Default still derives).
- codec/json.rs: optional `groups` on `TabsListPayload` + `TabsChangedPayload`
  (absent stays absent on canonical re-encode; present incl. `[]` round-trips).
- ext.rs: groups parsed tolerantly (malformed → `[]`, frame kept — tabs
  parse keeps its stricter drop-frame behavior); `MAX_EXT_GROUPS = 16` belt.
- session.rs: `SERVER_PROTO_VERSION` → "1.5"; `tabs_changed_frame` always
  emits `groups: Some(...)`. router.rs: tabs.list reply always emits groups.
- Tests: 3 new ext_relay scenarios (groups → watch, 17→16 belt truncation,
  `"groups": "garbage"` tolerant-degrade); integration pushes assert
  groupId + groups fields; router PopulatedTabs carries a group.

### Task 3 — Dart codec + Flutter UI (a08d992)
- remote_protocol: `GroupInfo` class (value-equal, toJson all four keys),
  `TabInfo.groupId`, `_groupList` parser (`_req` all four fields → fixture
  08 hard error), optional `groups` on TabsListMsg/TabsChangedMsg (raw-tabs
  null-check pattern). `version.dart` untouched ('1.1' precedent).
- connection_service: `TabsSnapshot.groups` (element-wise ==, Object.hash
  with hashAll); both parking sites default `msg.groups ?? const []`.
- tabs_store: `TabsViewState.groups`; commands untouched (view-only).
- browser_screen: `kGroupColors` (Chrome dark palette, 9 named colors, local
  consts NOT theme tokens) + `groupColor()` kMuted fallback; `_GroupHeader`
  (8px dot + 12/600 tinted title, empty title = dot alone, collapsed =
  Opacity(0.5) + unfold_less glyph, ZERO gesture handlers); `_TabsSection`
  inserts a header before each consecutive grouped run via a `{id: GroupInfo}`
  map — null/unresolved groupId renders flat (byte-identical row).
- Tests: +6 (equality incl. collapsed-flag, groups map-through, empty-groups
  flat view, header render + tint + single-header-per-run, collapsed dimming,
  view-only tap/long-press inertness, unresolved-groupId flat).

## Verification (final run, all green)

- `cargo test -p server-core`: 144 passed, 0 failed (102 unit + 10 ext_relay + 8 fixtures + 24 integration)
- `dart test` (remote_protocol): 12 passed (fixtures 06/07/08 picked up with zero harness edits)
- `flutter analyze`: no issues; `flutter test`: 478 passed, 0 failed
- `node --check extension/background.js`: clean; all new fixtures parse as JSON
- Grep gates: no `tabs.group*` wire command family exists (sole grep hit is
  the `tabs.groups` field access in browser_screen.dart); fixtures 01–05
  byte-untouched

## Deviations from Plan

**1. [Process] Executor ran inline, not as a subagent** — worktree spawn hit
the known stale-HEAD quirk (exit 42), re-dispatch without isolation was
declined by the user; the plan was executed inline in the main session on
master. Same commits, same verification.

**2. [Task 3, cosmetic] Header inset** — `_GroupHeader` carries a 4px left
inset (visual alignment with the 12px row padding); plan didn't specify.

## OUTSTANDING — Human E2E (extends the 260716-oi2 checklist)

1. Reload the unpacked extension (manifest changed: new `tabGroups`
   permission requires the reload arrow on chrome://extensions).
2. Create a named, colored tab group on the PC → phone shows the header with
   dot + title tinted the matching color within ~1 s; ungrouped tabs flat.
3. Collapse the group on the PC → header dims + unfold-less glyph appears;
   tabs remain listed and tappable.
4. Tap a grouped tab row → PC switches (groups add no gesture regressions);
   tap/long-press the header itself → nothing happens.
5. 1.4-compat: an older phone build against the 1.5 server still renders the
   flat list (unknown `groups` key ignored per D-05).
