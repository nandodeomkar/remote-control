# Phase 10: Keyboard rethink + Shortcuts tile - Pattern Map

**Mapped:** 2026-07-17
**Files analyzed:** 10 (5 modify, 4 new, 1 test-pair)
**Analogs found:** 10 / 10 (every new/modified file has a strong in-repo analog — this is an extend-existing-patterns phase, no green-field surfaces)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/remote_control/lib/keyboard/keyboard_screen.dart` (MODIFY — rebuild as PageView + persistent chips + bottom tabs) | screen | request-response (fire-and-forget key sends) | `keyboard_panel.dart` (owns FSM/held-set/D-12) + `media_screen.dart` (screen chrome) | exact (composed from two analogs) |
| Pad widgets (Type/Arrows/Numpad/Fn) — NEW, likely `lib/keyboard/key_pads.dart` or extend `key_rows.dart` | component | request-response (down/up + tap+mods) | `key_rows.dart` `KeyRows` + `_KeyCap` | exact — reuse `_KeyCap` verbatim |
| Bottom tab bar — NEW widget | component | event-driven (page nav, no sends) | `key_rows.dart` `KeyRowGroupSwitcher` | role-match (segment→tab) |
| Persistent modifier chip row — MODIFY (lift from `keyboard_panel.dart`) | component | request-response (hold down/up) | `keyboard_panel.dart` `_rows()` chip Row + `modifier_chip.dart` | exact — reuse `ModifierChip` verbatim |
| `keyboard.pad` prefs store — NEW | store | persistence (PrefsKv) | `key_rows.dart` `KeyRowGroupStore` / `KeyRowGroupNotifier` | exact — copy structure |
| Shortcuts screen — NEW `lib/shortcuts/shortcuts_screen.dart` | screen | request-response (tap+mods macros) | `media_screen.dart` (chrome + scroll) + `browser_screen.dart` (macro grid) | exact (composed) |
| `ShortcutButton` widget — NEW | component | request-response (single tap send) | `media_screen.dart` `_TransportButton` + `browser_screen.dart` `_BrowserKey` | exact — press-down + flash |
| Shortcut catalog registry — NEW | data/config | static registry | `browser_screen.dart` `kBrowserActions` (`BrowserActionSpec`) + `hub_screen.dart` `kHubTiles` | exact |
| `app/remote_control/lib/hub/hub_screen.dart` (MODIFY — insert Shortcuts tile at pos 3) | config | static registry | `hub_screen.dart` `kHubTiles` (self) | exact |
| `server/server-windows/src/executors/keymap.rs` (MODIFY — extend `CLIENT_KEY_CODES`, promote from `ROUTER_MACRO_CODES`) | config/mapping | transform (code→enigo Key) | `keymap.rs` `map_key` / `CLIENT_KEY_CODES` (self) | exact |
| `kClientKeyCodes` in `key_rows.dart` (MODIFY — mirror) | config | static list | `key_rows.dart` (self) | exact |
| Coverage tests: Rust `keymap_covers_all_codes` + Dart `key_rows_test.dart` vocabulary test (MODIFY) | test | assertion | both self | exact |

## Pattern Assignments

### `keyboard_screen.dart` — full rebuild (screen, request-response)

**Analogs:** `keyboard_panel.dart` (all the sacred logic) + `media_screen.dart` (chrome shell).

The rebuild MOVES the screen-level ownership currently in `_KeyboardPanelState` (FSM, `_heldCodes`, `_imeResetTick`, changes subscription, dispose flush) UP into the screen, and replaces the single `KeyRows` + `KeyRowGroupSwitcher` with a `PageView` of 4 pads + a bottom tab bar. `HiddenTextInput` moves OUTSIDE the PageView.

**Chrome shell to copy from `media_screen.dart` (lines 85-112):**
```dart
return Scaffold(
  resizeToAvoidBottomInset: true, // KEEP — raised IME pushes chips+tabs up
  backgroundColor: kBg,
  appBar: AppBar(
    backgroundColor: kBg,
    title: const Text('Keyboard', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kText)),
    actions: [ Padding(padding: const EdgeInsets.only(right: 16),
      child: Center(child: ConnectionHeaderChip.forService(_service))) ],
  ),
  body: SafeArea(child: Column(children: [
    ReconnectingBannerSlot(visible: status.chip == ChipStatus.reconnecting, onRetry: _service.retryNow),
    // Expanded PageView ... chips ... tab bar
  ])),
);
```
Note: current `keyboard_screen.dart` has NO `ConnectionHeaderChip` or `ReconnectingBannerSlot` — UI-SPEC §Screen-1 adds both; copy the exact idiom from `media_screen.dart`.

**Service wiring + auth gate (copy from current `keyboard_screen.dart` lines 62-79):**
```dart
_service = ref.read(connectionServiceProvider);
_imeProducer = ImeDiffProducer(emit: _service.sendReliable);
// build():
final status = ref.watch(connectionStatusProvider);
final authed = status.chip == ChipStatus.connected;
```

**FSM + held-set + effect wiring — LIFT VERBATIM from `keyboard_panel.dart`:**
- `_fsm` (lines 101), `_heldCodes` (110), `_imeResetTick` (121)
- `_sendEffects` (188-197), `_onChipTap`/`_onChipLongPress` (199-209), `_onKeyDown`/`_onKeyUp`/`_onKeyTapWithMods` (211-229)
- changes subscription + `_onDisconnected` (124-150) — the D-12 reset
- `dispose()` flush (165-184) — the CR-01 screen-level flush
These are the sacred invariants; they must survive the rebuild unchanged (see Shared Patterns → Stuck-key invariants).

**Modifier chip row — copy `keyboard_panel.dart` lines 231-259**, but the row is now rendered at screen level, persistent, OUTSIDE/below the PageView. `_chipMods` const + the `Expanded`+`ModifierChip` Row is verbatim.

**IME raise/lower — adapt `keyboard_panel.dart` `didUpdateWidget` (152-162):**
```dart
// onPageChanged: index 0 → imeFocusNode.requestFocus(); index != 0 → imeFocusNode.unfocus();
// first entry when default page is Type: post-frame requestFocus (initState pattern lines 124-131)
```

**PageView pad host (NEW structure, per UI-SPEC §Pad layouts):**
```dart
Expanded(child: PageView(
  controller: _pageController,
  allowImplicitScrolling: false, // CR-01: dispose outgoing pad's caps → their up fires
  onPageChanged: _onPageChanged,
  children: [TypePad(...), ArrowsPad(...), NumpadPad(...), FnPad(...)],
)),
```
Do NOT add `AutomaticKeepAlive` / keep-alive — cap dispose-on-page-leave IS the release mechanism (CR-01).

---

### Pad widgets (component, request-response) — reuse `_KeyCap`

**Analog:** `key_rows.dart` `_KeyCap` (lines 326-457) + `KeyCapDef` (134-149).

`_KeyCap` is currently private. Either (a) make it public / extract to a shared file, or (b) keep pads inside `key_rows.dart`. The press model MUST be reused unchanged — it encodes IN-04 (always-wired releases), CR-01 (dispose release), D-11 (down/up hold), D-10 (deferred tap+mods):

**The emission model (`_KeyCap` lines 364-406) is load-bearing — reuse, do not rewrite:**
```dart
void _onTapDown(TapDownDetails _) {
  setState(() => _pressed = true);
  widget.onPressHaptic?.call();
  _live = true;
  _deferred = widget.hasArmedMods();
  if (!_deferred) widget.onKeyDown(widget.def.code); // D-11 hold
}
void _onTapUp(TapUpDetails _) {
  setState(() => _pressed = false);
  if (!_live) return;
  _live = false;
  if (_deferred) widget.onKeyTapWithMods(widget.def.code); // D-10 combo
  else widget.onKeyUp(widget.def.code);
}
void _onTapCancel() { /* IN-04: canceled non-deferred press still releases */ }
@override
void dispose() { if (_live && !_deferred) widget.onKeyUp(widget.def.code); } // CR-01
```

**Cap visual (lines 408-451):** `kSurface` fill, `kHairline`/`kAccent` border, radius 8, `minWidth:48 minHeight:48`, `GestureDetector` (NOT InkWell — no ripple on caps). `onTapDown` gated on `enabled`; `onTapUp`/`onTapCancel` ALWAYS wired (IN-04, line 437).

**New cap def tables** (extend the `key_rows.dart` const-table pattern, lines 153-202): Type-pad slim row `[Esc, Tab, Up, Down, Left, Right, Del]` reuses existing defs; Arrows/Numpad/Fn reuse `kNavArrowCaps`/`kNumCaps`/`kFnCaps`. UI-SPEC wants `Expanded`-flex sizing (fill height) instead of the current fixed `width:` — pass `width: null` and wrap caps in `Expanded`. The `Home/End/PgUp/PgDn` top row on Arrows pulls from `kNavClusterCaps`.

**`capsForGroup` equivalent (line 205)** is the widget-test coverage seam — add a `capsForPad(pad)` (or per-pad const lists) the vocabulary test iterates.

---

### Bottom tab bar (component, event-driven) — analog `KeyRowGroupSwitcher`

**Analog:** `key_rows.dart` `KeyRowGroupSwitcher` (lines 462-515) — the accent-underline segment selector. Deltas per UI-SPEC §Bottom tab bar: 56px bar, icon-above-label (24px icon + 12/400 label, 4px gap), 2px accent underline at TOP edge, `hapticTick()` + 200ms PageView animate on tap, ALWAYS interactive (no gated variant). Reuse the `for (final g in ...) Expanded(child: InkWell(...))` shape (lines 484-511).

---

### `keyboard.pad` prefs store (store, persistence) — analog `KeyRowGroupStore`

**Analog:** `key_rows.dart` `KeyRowGroupStore` (69-95) + `KeyRowGroupNotifier` (105-129) + providers (98-100, 127-129). Copy structure exactly with new key and enum:
```dart
const String kKeyboardPadPrefsKey = 'keyboard.pad'; // NEW key
enum KeyboardPad { type, arrows, numpad, fn }        // default: type
// load(): try prefs.getString → firstWhere(name == stored, orElse: () => KeyboardPad.type)
//   on Object → return KeyboardPad.type   (degrade-to-default: broken read must not take keyboard down)
// Notifier.build(): synchronous KeyboardPad.type seed + unawaited(_load(...))
// set(pad): state = pad; unawaited(store.save(pad));  (fire-and-forget)
```
LEAVE `keyboard.rowGroup` / `KeyRowGroupStore` UNTOUCHED — the trackpad-docked `KeyboardPanel` (D-07, out of scope) still owns it.

---

### Shortcuts screen (screen, request-response) — analogs `media_screen.dart` + `browser_screen.dart`

**Analog chrome:** `media_screen.dart` lines 85-116 — same Scaffold/AppBar/`ConnectionHeaderChip`/`ReconnectingBannerSlot`/`SingleChildScrollView(padding: fromLTRB(16, 32, 16, 16))`. Title `'Shortcuts'`.

**Analog grid + gating:** `browser_screen.dart` `BrowserMacroGrid` (118-171) for the 2-column build-from-registry loop and the odd-tail half-width-beside-empty pattern; `hub_screen.dart` `HubTileGrid._build` (161-190) is the alternate 2-col chunker if sections need it.

**Service wiring + gate:** copy `media_screen.dart` lines 54-74 (`_service = ref.read(connectionServiceProvider)`, `authed = status.chip == ChipStatus.connected`). Sends go on `_service.sendReliable(KeyMsg(code:.., action:'tap', mods:[..]))`.

---

### `ShortcutButton` (component, request-response) — analog `_TransportButton`

**Analog:** `media_screen.dart` `_TransportButton` (219-278) — the canonical press-DOWN + haptic + 100ms accent flash + muted-not-red gate. Also `browser_screen.dart` `_BrowserKey` (175+) for a rectangular macro variant.

**Press behavior to copy (`_TransportButton` lines 238-250):**
```dart
void _fire() {
  widget.onPress();          // send KeyMsg tap+mods on reliable path
  hapticTick();
  setState(() => _pressed = true);
  Future.delayed(const Duration(milliseconds: 100), () {
    if (!mounted) return;
    setState(() => _pressed = false);
  });
}
// onTapDown: widget.enabled ? (_) => _fire() : null;  ← press-down, gated entry
```
**Gating (lines 254-259):** `borderColor = _pressed ? kAccent : kHairline`; `iconColor = !enabled ? kMuted : _pressed ? kAccent : kText`. Fire-and-forget — NEVER show optimistic/result state (UI-SPEC §button, matches Browser). Visual per UI-SPEC §Shortcut button anatomy: `kSurface`, radius 12, minHeight 64, 12px padding, `Row[icon 24, 12 gap, Expanded Column(effect 14/600, 2 gap, combo 12/400 kMuted)]`.

---

### Shortcut catalog registry (data/config) — analog `kBrowserActions` / `kHubTiles`

**Analog:** `browser_screen.dart` `BrowserActionSpec` + `kBrowserActions` (80-113); `hub_screen.dart` `HubTileSpec` + `kHubTiles` (55-133). One ordered data structure drives BOTH render and the vocabulary coverage test.

```dart
class ShortcutSpec {
  final String label;   // effect copy: 'Show desktop'
  final String combo;   // subtext: 'Win+D'
  final IconData icon;  // Symbols.*_rounded
  final String code;    // key.code — MUST be in kClientKeyCodes
  final List<String> mods; // wire strings: 'ctrl'|'alt'|'shift'|'win'
  const ShortcutSpec({...});
}
class ShortcutSection { final String header; final List<ShortcutSpec> items; }
const List<ShortcutSection> kShortcutCatalog = [ /* 4 sections, 25 buttons — verbatim UI-SPEC tables */ ];
```
The 25 rows (labels/combos/codes/mods) are LOCKED in UI-SPEC §Shortcut catalog (lines 224-269) — copy them byte-for-byte. Wire mod strings confirmed in `remote_protocol` `KeyMsg` (json_codec.dart:476) and `modifier_fsm.dart` `_kWireMods` (`ctrl`/`alt`/`shift`/`win`).

---

### `hub_screen.dart` MODIFY — insert Shortcuts tile at position 3

**Analog:** self, `kHubTiles` (82-133). Insert after Keyboard (pos 2), before Media:
```dart
HubTileSpec(label: 'Shortcuts', icon: Symbols.bolt_rounded, builder: (_) => const ShortcutsScreen()),
```
Add the `import '../shortcuts/shortcuts_screen.dart';`. New order = 9 tiles; `HubTileGrid` already handles the odd tail (half-width beside empty slot, lines 165-180) — no grid change. Opened via `HubScreen._open` (271-282) → `BubbleScaffold` centrally; the screen stays bubble-unaware. `showBubble` defaults true (correct for Shortcuts).

---

### `keymap.rs` MODIFY — extend vocabulary (config/transform)

**Analog:** self. Single source of truth; the Dart `kClientKeyCodes` mirrors it byte-for-byte.

**Add to `CLIENT_KEY_CODES` (lines 44-56):** letters `A C D E F I R S V X Y Z`, main-row `0`, `PrintScreen`. **Promote** `T W Plus Minus` from `ROUTER_MACRO_CODES` (line 66) INTO `CLIENT_KEY_CODES` (remove from the router list or leave — but the client now emits them, so they belong in the client vocab; keep `keymap_covers_all_codes` green).

**Add to `map_key` (lines 79-148)** following the existing `Key::Unicode` letter precedent (lines 141-145):
```rust
"A" => Key::Unicode('a'), "C" => Key::Unicode('c'), "D" => Key::Unicode('d'),
"E" => Key::Unicode('e'), "F" => Key::Unicode('f'), "I" => Key::Unicode('i'),
"R" => Key::Unicode('r'), "S" => Key::Unicode('s'), "V" => Key::Unicode('v'),
"X" => Key::Unicode('x'), "Y" => Key::Unicode('y'), "Z" => Key::Unicode('z'),
"0" => Key::Unicode('0'),        // main-row zero for Ctrl+0 (distinct from Num0)
"PrintScreen" => Key::PrintScr,  // VK_SNAPSHOT — bare + Win-modified screenshot
// T/W already present (141-142); Plus/Minus already present (144-145) — reuse verbatim
```
**Zoom naming (discretion resolved in UI-SPEC line 291):** reuse existing `Plus`→`Key::Unicode('=')` and `Minus`→`Key::Unicode('-')` — the `'='` resolution is the locked Pitfall-11 fix. Do NOT introduce `Equal`. No `SERVER_PROTO_VERSION` bump — message shape unchanged, only vocabulary grows (unknown codes still drop silently, T-04-02).

---

### Coverage tests MODIFY (test, assertion)

**Rust — `keymap.rs` `keymap_covers_all_codes` (177-185):** already iterates `CLIENT_KEY_CODES`; the promoted `T/W/Plus/Minus` may leave `ROUTER_MACRO_CODES` — keep `router_macro_codes_covered` (202-209) consistent with whatever stays in that list.

**Dart — `key_rows_test.dart` (38-50):** the vocabulary gate iterates `capsForGroup(group)` and asserts `kClientKeyCodes contains def.code`. Extend to also cover the new pad cap tables AND the shortcut catalog codes:
```dart
for (final section in kShortcutCatalog)
  for (final s in section.items)
    expect(kClientKeyCodes, contains(s.code), reason: '${s.label} code ${s.code} must be in locked keymap.rs vocab');
```
Plus a Dart↔Rust lockstep assertion if one exists (grep confirmed `key_rows_test.dart` currently asserts caps-only).

## Shared Patterns

### Stuck-key invariants (SACRED — carried from `keyboard_panel.dart`; any new pad/cap/screen MUST preserve)

**Apply to:** the rebuilt `keyboard_screen.dart` and every pad/cap.

- **CR-01 cap-dispose release** — `_KeyCap.dispose()` (key_rows.dart 396-406): a cap disposed mid-hold (page switch, screen pop) fires `onKeyUp` for non-deferred live presses. PageView MUST use default child lifecycle (`allowImplicitScrolling: false`, no keep-alive) so leaving a pad disposes its caps.
- **CR-02 held-set tracking** — `_heldCodes` (keyboard_panel.dart 110); `_onKeyUp` only sends when `remove()` succeeds (216-223) — idempotent with cap-level dispose release.
- **IN-04 always-wired releases** — `_KeyCap` `onTapUp`/`onTapCancel` never nulled (key_rows.dart 437, 386-393); a PageView drag that claims the gesture cancels the tap and still releases. Only press ENTRY (`onTapDown`) is auth-gated.
- **D-12 disconnect reset** — `_onDisconnected` (keyboard_panel.dart 145-150): `_fsm.disconnected()` (zero effects), `_heldCodes.clear()` (no ups), `_imeResetTick++` (CR-01 IME wipe). Driven off `service.changes` + `isDisconnected()` probe (133-138).
- **Screen dispose flush** — `dispose()` (keyboard_panel.dart 165-184): on a LIVE socket only, flush every owed `up` from `_heldCodes` + `_sendEffects(_fsm.releaseAll())`; skip entirely when disconnected (CONN-07 already freed real keys; sending into a NEW session is wrong).

### Screen chrome
**Source:** `media_screen.dart` lines 85-116 (AppBar `kBg` + 16/600 title + `ConnectionHeaderChip.forService` + `ReconnectingBannerSlot` + `SingleChildScrollView` md/xl padding).
**Apply to:** Shortcuts screen; the Keyboard rebuild's app bar (adds the chip + banner it currently lacks).

### Gated-not-red action button
**Source:** `media_screen.dart` `_TransportButton` (219-278) — press-down send + `hapticTick()` + 100ms accent flash; `!enabled ? kMuted` face, border stays `kHairline`, entry null.
**Apply to:** `ShortcutButton`. (`browser_screen.dart` `_BrowserKey` is the rectangular twin.)

### Auth gate
**Source:** every tool screen — `final authed = ref.watch(connectionStatusProvider).chip == ChipStatus.connected;` (media_screen.dart 73-74, keyboard_screen.dart 77-78).
**Apply to:** Shortcuts screen (`enabled: authed` on every button) and the Keyboard rebuild (chips + caps gated on `authed`).

### Registry-driven render + coverage
**Source:** `browser_screen.dart` `kBrowserActions` + `hub_screen.dart` `kHubTiles` — one ordered const list drives both the grid build and the vocabulary/coverage test.
**Apply to:** `kShortcutCatalog`, the new pad cap tables, and `kHubTiles` insertion.

### No inline copy literals
**Source:** house rule (hub_screen `kSettingsTitle`, keyboard_screen `kKeyboardTitle`/`kKeyboardHint`). Every label/combo/section-header/title ships as a named const. Tab labels, section headers, effect labels, combo subtexts all bound in UI-SPEC §Copywriting Contract.

### Icon axes / no classic Icons
**Source:** `material_symbols_icons` `Symbols.*_rounded` only (banned `Icons.*` via `icons_guard_test`). Axes pinned in `buildAppTheme()`. Substitute nearest rounded glyph if a named symbol is missing from the pinned package (UI-SPEC allows this for tab + shortcut icons).

## No Analog Found

None. Every surface extends an existing pattern.

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| — | — | — | All 10 files have exact or role-match in-repo analogs. |

## Metadata

**Analog search scope:** `app/remote_control/lib/{keyboard,media,hub,browser}/`, `app/remote_control/test/keyboard/`, `app/packages/remote_protocol/lib/src/`, `server/server-windows/src/executors/`
**Files scanned:** keyboard_screen.dart, keyboard_panel.dart, key_rows.dart, modifier_fsm.dart, media_screen.dart, hub_screen.dart, browser_screen.dart, keymap.rs, key_rows_test.dart, json_codec.dart
**Pattern extraction date:** 2026-07-17
