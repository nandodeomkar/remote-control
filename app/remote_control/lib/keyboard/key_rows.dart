/// The shared key-cap layer (KEY-02/KEY-04, D-10/D-11): the client half of
/// the locked `key.code` vocabulary, the [KeyCapDef] tables both keyboard
/// surfaces lay out, the shared [KeyCap] widget that owns the press model,
/// and the two mount-point pad stores.
///
/// The filename is a historical artifact — it named a widget that is gone
/// since 260809-ipc, when the trackpad-docked panel adopted the same four
/// pads as the full-screen keyboard. What remains is the vocabulary and the
/// press model, both shared BY REFERENCE by both surfaces.
///
/// Widget-only and service-agnostic (mouse_buttons house style): key presses
/// surface through injected callbacks, so the widget tests need no service
/// fake. Each surface wires those callbacks to its shared
/// `KeyboardInputController`, which sends on the reliable path.
///
/// # Key-cap emission model (D-11 + D-10 interplay, plan-locked)
///
/// On press-down — if NO armed modifiers are pending — the cap emits
/// [KeyCap.onKeyDown] immediately; release emits [KeyCap.onKeyUp]. A quick
/// press is a down/up pair (≈ tap); a HOLD leaves the key down so WINDOWS
/// autorepeats until the up (KEY-04 — server-side repeat, never client
/// tap-spam). If armed mods ARE pending at press-down, the cap defers and
/// emits [KeyCap.onKeyTapWithMods] on release instead — the combo path
/// (`key {action: tap, mods: [...]}`), after which the surface auto-resets
/// the armed chips (D-10).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/device_store.dart';
import '../theme/tokens.dart';

/// The canonical client `key.code` vocabulary — a byte-for-byte mirror of
/// `server/server-windows/src/executors/keymap.rs` `CLIENT_KEY_CODES`.
///
/// keymap.rs is the SINGLE SOURCE OF TRUTH (04-02, Open Q3): any change
/// lands in BOTH files, and both sides are coverage-tested (the Rust
/// `keymap_covers_all_codes` gate there; the key_rows widget test here).
/// A string missing from keymap.rs is dropped SILENTLY server-side
/// (T-04-02) — never emit a code that is not in this list.
const List<String> kClientKeyCodes = [
  // Nav cluster (UI-SPEC key rows: Nav group)
  'Esc', 'Tab', 'Home', 'End', 'PgUp', 'PgDn', 'Del',
  // Arrows (inverted-T cluster)
  'Up', 'Down', 'Left', 'Right',
  // Function row
  'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
  // Numpad (3-column grid + Enter + decimal)
  'Num0', 'Num1', 'Num2', 'Num3', 'Num4', 'Num5', 'Num6', 'Num7', 'Num8',
  'Num9', 'NumEnter', 'NumDot',
  // Modifier hold codes (D-10 locked-modifier physical hold path)
  'ControlLeft', 'AltLeft', 'ShiftLeft', 'WinLeft',
  // Shortcut vocabulary (letters, main-row zero, PrintScreen, promoted
  // browser macros) — 10-01, byte-for-byte with keymap.rs CLIENT_KEY_CODES.
  // Consumed by the 10-02 Shortcuts catalog; letters chord via Ctrl/Win,
  // '0' is the main-row zero (distinct from Num0), T/W/Plus/Minus were
  // promoted out of the server's ROUTER_MACRO_CODES.
  'A', 'C', 'D', 'E', 'F', 'I', 'R', 'S', 'V', 'X', 'Y', 'Z',
  '0', 'PrintScreen', 'T', 'W', 'Plus', 'Minus',
];

// ── Cap definitions (the test seam: iterate THESE, not the screen) ─────────

/// One key cap: the wire code it emits + its face (label or icon).
class KeyCapDef {
  /// The `key.code` sent on the wire — MUST be in [kClientKeyCodes].
  final String code;

  /// Visible label (null for icon caps).
  final String? label;

  /// Icon face (arrows) — carries [tooltip] for accessibility.
  final IconData? icon;

  /// Tooltip for icon caps ("Up"/"Down"/"Left"/"Right").
  final String? tooltip;

  /// Creates a cap definition.
  const KeyCapDef(this.code, {this.label, this.icon, this.tooltip});
}

/// The four arrow caps (inverted-T: Up above Left/Down/Right).
const List<KeyCapDef> kNavArrowCaps = [
  KeyCapDef('Up', icon: Symbols.arrow_upward_rounded, tooltip: 'Up'),
  KeyCapDef('Left', icon: Symbols.arrow_back_rounded, tooltip: 'Left'),
  KeyCapDef('Down', icon: Symbols.arrow_downward_rounded, tooltip: 'Down'),
  KeyCapDef('Right', icon: Symbols.arrow_forward_rounded, tooltip: 'Right'),
];

/// F1..F12 caps (wrapping grid).
const List<KeyCapDef> kFnCaps = [
  KeyCapDef('F1', label: 'F1'),
  KeyCapDef('F2', label: 'F2'),
  KeyCapDef('F3', label: 'F3'),
  KeyCapDef('F4', label: 'F4'),
  KeyCapDef('F5', label: 'F5'),
  KeyCapDef('F6', label: 'F6'),
  KeyCapDef('F7', label: 'F7'),
  KeyCapDef('F8', label: 'F8'),
  KeyCapDef('F9', label: 'F9'),
  KeyCapDef('F10', label: 'F10'),
  KeyCapDef('F11', label: 'F11'),
  KeyCapDef('F12', label: 'F12'),
];

/// Numpad caps, row-major over the 3-column grid:
/// 7 8 9 / 4 5 6 / 1 2 3 / 0 Enter '.'.
const List<KeyCapDef> kNumCaps = [
  KeyCapDef('Num7', label: '7'),
  KeyCapDef('Num8', label: '8'),
  KeyCapDef('Num9', label: '9'),
  KeyCapDef('Num4', label: '4'),
  KeyCapDef('Num5', label: '5'),
  KeyCapDef('Num6', label: '6'),
  KeyCapDef('Num1', label: '1'),
  KeyCapDef('Num2', label: '2'),
  KeyCapDef('Num3', label: '3'),
  KeyCapDef('Num0', label: '0'),
  KeyCapDef('NumEnter', label: 'Enter'),
  KeyCapDef('NumDot', label: '.'),
];

// ── Pad cap definitions (10-03; both surfaces since 260809-ipc) ───────────
//
// These tables + [capsForPad] + [KeyboardPad] serve BOTH keyboards: the
// full-screen swipeable one (10-04/10-05) and the trackpad-docked panel,
// which adopted the same four pads in 260809-ipc. There is no second cap
// vocabulary anywhere.

/// The Type pad's slim extras row (UI-SPEC §Pad layouts — Type pad):
/// `Esc | Tab | ← | ↑ | ↓ | → | Del`, docked under the IME canvas.
///
/// Reuses the [kNavArrowCaps] codes and faces — the arrows carry their icon
/// + tooltip.
const List<KeyCapDef> kTypeExtrasCaps = [
  KeyCapDef('Esc', label: 'Esc'),
  KeyCapDef('Tab', label: 'Tab'),
  KeyCapDef('Left', icon: Symbols.arrow_back_rounded, tooltip: 'Left'),
  KeyCapDef('Up', icon: Symbols.arrow_upward_rounded, tooltip: 'Up'),
  KeyCapDef('Down', icon: Symbols.arrow_downward_rounded, tooltip: 'Down'),
  KeyCapDef('Right', icon: Symbols.arrow_forward_rounded, tooltip: 'Right'),
  KeyCapDef('Del', label: 'Del'),
];

/// The Arrows pad's top row (UI-SPEC §Pad layouts — Arrows pad):
/// `Home | End | PgUp | PgDn`, above the large inverted-T ([kNavArrowCaps]).
const List<KeyCapDef> kArrowsTopCaps = [
  KeyCapDef('Home', label: 'Home'),
  KeyCapDef('End', label: 'End'),
  KeyCapDef('PgUp', label: 'PgUp'),
  KeyCapDef('PgDn', label: 'PgDn'),
];

/// The Fn pad's full-width Esc cap (UI-SPEC §Pad layouts — Fn pad,
/// user-locked: Esc on this pad too), rendered above the F1–F12 grid.
const KeyCapDef kFnEscCap = KeyCapDef('Esc', label: 'Esc');

/// The full-screen keyboard's swipeable pads (UI-SPEC §Pad layouts), in
/// PageView order. [type] is the default (see [kKeyboardPadPrefsKey]).
enum KeyboardPad {
  /// System IME + the slim extras row ([kTypeExtrasCaps]).
  type,

  /// [kArrowsTopCaps] over the large inverted-T ([kNavArrowCaps]).
  arrows,

  /// The calculator-layout numpad ([kNumCaps]).
  numpad,

  /// [kFnEscCap] over the F1–F12 grid ([kFnCaps]).
  fn,
}

/// Every cap definition a [pad] renders — the widget-test coverage seam
/// (iterate THIS, not the screen): every returned code MUST be in
/// [kClientKeyCodes], else the key is dead server-side (T-04-02).
List<KeyCapDef> capsForPad(KeyboardPad pad) => switch (pad) {
      KeyboardPad.type => kTypeExtrasCaps,
      KeyboardPad.arrows => [...kArrowsTopCaps, ...kNavArrowCaps],
      KeyboardPad.numpad => kNumCaps,
      KeyboardPad.fn => [kFnEscCap, ...kFnCaps],
    };

// ── Pad persistence (10-03 + 260809-ipc: one model, two mount-point keys) ─

/// The shared_preferences key holding the last-open pad (10-UI-SPEC §Pad
/// persistence). Deliberately DISTINCT from [kPanelPadPrefsKey]: the
/// full-screen keyboard and the D-07 trackpad-docked panel persist their
/// landing pads independently — see that constant for why.
const String kKeyboardPadPrefsKey = 'keyboard.pad';

/// The shared_preferences key holding the trackpad-docked panel's last-open
/// pad (260809-ipc, D-94). Deliberately DISTINCT from [kKeyboardPadPrefsKey]:
/// ONE model, TWO mount-point keys.
///
/// The two surfaces persist separately because the panel's pad choice has a
/// physical consequence the screen's does not — it resizes the live trackpad
/// beside it. A shared key would let a tap on the full-screen keyboard
/// silently shrink the trackpad the next time the panel opens, for a reason
/// the user cannot see. The panel is also dominated by Type and Arrows (it
/// exists to type WHILE the cursor is live) where the full screen is where
/// Numpad and Fn get real use, so a shared key would have each surface
/// continually yanking the other's landing pad.
const String kPanelPadPrefsKey = 'keyboard.panelPad';

/// The retired docked-panel preference, read exactly once by the panel store
/// and never written. Private, and the ONLY surviving reference to it
/// anywhere: the migration below maps it into [kPanelPadPrefsKey] on first
/// load, so the legacy read never happens a second time.
const String _kRetiredPanelPrefsKey = 'keyboard.rowGroup';

/// How a retired docked-panel selection becomes a pad.
///
/// The two deliberate choices have exact successors. Everything else — the
/// old default nobody chose, an unset key, an unknown string — lands on
/// [KeyboardPad.type]: that value's caps split across Type and Arrows so it
/// has no single successor, and the slim Type strip is the least disruptive
/// first open for an upgrading user.
const Map<String, KeyboardPad> _kRetiredPanelPads = {
  'fn': KeyboardPad.fn,
  'num': KeyboardPad.numpad,
};

/// Typed store for a last-open pad over the [PrefsKv] seam (non-secret by
/// rule; never secure storage).
///
/// Parameterised by [key] so ONE model serves both mount points: the
/// full-screen keyboard on [kKeyboardPadPrefsKey], the trackpad-docked panel
/// on [kPanelPadPrefsKey].
class KeyboardPadStore {
  final PrefsKv _prefs;

  /// Which prefs key this store reads and writes.
  final String key;

  /// Whether an unset [key] falls back to a ONE-TIME read of the retired
  /// docked-panel preference (the panel store only). See [load].
  final bool migrateRetiredPanelKey;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  KeyboardPadStore({
    PrefsKv? prefs,
    this.key = kKeyboardPadPrefsKey,
    this.migrateRetiredPanelKey = false,
  }) : _prefs = prefs ?? SharedPrefsKv();

  /// The persisted pad; [KeyboardPad.type] when unset, unknown, or when the
  /// platform read fails — a broken pref must never take the keyboard down
  /// (T-10-04); the default pad is always available.
  ///
  /// When [migrateRetiredPanelKey] is set and [key] is UNSET, the retired
  /// docked-panel preference is read once, mapped per [_kRetiredPanelPads]
  /// and written straight back under [key] — so the legacy read happens on
  /// exactly one load, ever, and no upgrading user loses their choice.
  Future<KeyboardPad> load() async {
    try {
      final stored = await _prefs.getString(key);
      if (stored != null || !migrateRetiredPanelKey) return _padFor(stored);

      final retired = await _prefs.getString(_kRetiredPanelPrefsKey);
      final migrated = _kRetiredPanelPads[retired] ?? KeyboardPad.type;
      await save(migrated);
      return migrated;
    } on Object {
      return KeyboardPad.type;
    }
  }

  static KeyboardPad _padFor(String? stored) => KeyboardPad.values.firstWhere(
        (pad) => pad.name == stored,
        orElse: () => KeyboardPad.type,
      );

  /// Persists [pad] (its enum name: 'type' | 'arrows' | 'numpad' | 'fn')
  /// under this store's [key].
  Future<void> save(KeyboardPad pad) => _prefs.setString(key, pad.name);
}

/// The [KeyboardPadStore] singleton (overridable in tests).
final keyboardPadStoreProvider = Provider<KeyboardPadStore>(
  (ref) => KeyboardPadStore(),
);

/// Riverpod 3 unified [Notifier] over the last-open pad: synchronous
/// [KeyboardPad.type] seed (the default), async load on build,
/// persist-through on [set].
class KeyboardPadNotifier extends Notifier<KeyboardPad> {
  @override
  KeyboardPad build() {
    // Seed synchronously with the default so the first frame renders;
    // replace with the persisted value as soon as it loads.
    unawaited(_load(ref.watch(keyboardPadStoreProvider)));
    return KeyboardPad.type;
  }

  Future<void> _load(KeyboardPadStore store) async {
    state = await store.load();
  }

  /// Selects [pad], applying live and persisting immediately
  /// (fire-and-forget — a failed prefs write costs persistence only).
  void set(KeyboardPad pad) {
    state = pad;
    unawaited(ref.read(keyboardPadStoreProvider).save(pad));
  }
}

/// The persisted last-open pad the full-screen keyboard's PageView binds to.
final keyboardPadProvider = NotifierProvider<KeyboardPadNotifier, KeyboardPad>(
  KeyboardPadNotifier.new,
);

/// The trackpad-docked panel's store: the SAME model on its own mount-point
/// key, with the one-time migration of the retired preference enabled.
final panelPadStoreProvider = Provider<KeyboardPadStore>(
  (ref) => KeyboardPadStore(
    key: kPanelPadPrefsKey,
    migrateRetiredPanelKey: true,
  ),
);

/// Riverpod 3 unified [Notifier] over the docked panel's last-open pad —
/// [KeyboardPadNotifier]'s twin over [panelPadStoreProvider].
class PanelPadNotifier extends Notifier<KeyboardPad> {
  @override
  KeyboardPad build() {
    // Seed synchronously with the default so the first frame renders;
    // replace with the persisted (or migrated) value as soon as it loads.
    unawaited(_load(ref.watch(panelPadStoreProvider)));
    return KeyboardPad.type;
  }

  Future<void> _load(KeyboardPadStore store) async {
    state = await store.load();
  }

  /// Selects [pad], applying live and persisting immediately
  /// (fire-and-forget — a failed prefs write costs persistence only).
  void set(KeyboardPad pad) {
    state = pad;
    unawaited(ref.read(panelPadStoreProvider).save(pad));
  }
}

/// The persisted last-open pad the trackpad-docked panel's PageView binds to.
final panelPadProvider = NotifierProvider<PanelPadNotifier, KeyboardPad>(
  PanelPadNotifier.new,
);

// ── Widgets ────────────────────────────────────────────────────────────────

/// One key cap: press-down branch capture + pressed accent state
/// (UI-SPEC key-cap state table).
///
/// PUBLIC and SHARED (10-03): the D-07 docked panel and the full-screen
/// keyboard mount the SAME widget through the SAME four pads, so the emission
/// model documented at the library top — D-11 hold, D-10 deferred combo,
/// IN-04 always-wired releases, CR-01 dispose release — is shared by
/// reference and can never drift between the two surfaces. Reuse it; do not
/// clone its press logic.
class KeyCap extends StatefulWidget {
  /// The cap this widget renders and emits for.
  final KeyCapDef def;

  /// False renders the muted, non-interactive (press-entry gated) state.
  final bool enabled;

  /// Fixed width (null sizes to the content + the [minWidth] floor).
  final double? width;

  /// The width floor — 48px (the touch-target minimum) by default.
  ///
  /// Relaxable ROW-LOCALLY (UI-SPEC §Spacing exceptions): the full-screen
  /// keyboard's Type pad shares one row between 7 caps, so on a narrow phone
  /// each is ~40–44dp wide. Only the WIDTH floor ever relaxes — the height
  /// floor below is fixed at 48 and is what keeps the target tappable.
  ///
  /// Note this floor only binds under LOOSE width constraints (the docked
  /// panel's `Wrap`); under an `Expanded` cell the parent's tight width wins
  /// via [BoxConstraints.enforce] regardless. It is declared here so the
  /// relaxation is explicit at the call site rather than implicit in layout.
  final double minWidth;

  /// Breathing room around the face — 12px each side by default.
  ///
  /// The pads size caps by `Expanded` flex (the cell owns the width), so they
  /// relax this: 12px each side would squeeze a 7-across row's labels off a
  /// ~40dp cap. This is the seam that does the real work for the Type row.
  final EdgeInsetsGeometry padding;

  /// Label face size — 14 (Body) by default, the docked panel's rows.
  ///
  /// UI-SPEC §Typography: the pads' large caps use 16 (Heading) and the
  /// numpad's digit faces 28 (Display).
  final double labelSize;

  /// Label face weight — w400 by default; the pads' large caps use w600
  /// (UI-SPEC §Typography). Only w400 and w600 exist in this design system.
  final FontWeight labelWeight;

  /// Icon face size — 20 by default (the docked rows and the Type pad's slim
  /// row); the Arrows pad's inverted-T uses 28 (UI-SPEC §Typography).
  final double iconSize;

  /// Press-down with no armed mods: `key {action: down}` (KEY-04 hold).
  final void Function(String code) onKeyDown;

  /// Release of a non-deferred press: `key {action: up}`.
  final void Function(String code) onKeyUp;

  /// Release of a DEFERRED press: `key {action: tap, mods: [...]}` (D-10).
  final void Function(String code) onKeyTapWithMods;

  /// Polled at press-down to pick the down/up vs tap+mods branch.
  final bool Function() hasArmedMods;

  /// Fired on every press-down (the haptic tick — UI-SPEC: on key-down).
  final VoidCallback? onPressHaptic;

  /// Creates a key cap.
  const KeyCap({
    super.key,
    required this.def,
    required this.enabled,
    required this.onKeyDown,
    required this.onKeyUp,
    required this.onKeyTapWithMods,
    required this.hasArmedMods,
    this.width,
    this.minWidth = 48,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.labelSize = 14,
    this.labelWeight = FontWeight.w400,
    this.iconSize = 20,
    this.onPressHaptic,
  });

  @override
  State<KeyCap> createState() => KeyCapState();
}

/// The [KeyCap] state — public with its widget; the press bodies below are
/// the sacred emission model (see the library doc).
class KeyCapState extends State<KeyCap> {
  bool _pressed = false;

  /// The branch captured at press-down: true = armed mods were pending, so
  /// the release fires the tap+mods combo instead of an up.
  bool _deferred = false;

  /// True while a press that FIRED its press-down branch (down sent, or a
  /// deferred combo captured) still owes a release. The guard that lets
  /// [_onTapUp]/[_onTapCancel] be always-wired (IN-04) without making
  /// presses that STARTED disabled emit anything.
  bool _live = false;

  void _onTapDown(TapDownDetails _) {
    setState(() => _pressed = true);
    widget.onPressHaptic?.call();
    _live = true;
    _deferred = widget.hasArmedMods();
    if (!_deferred) {
      // D-11: real key down — Windows autorepeats until the release's up.
      widget.onKeyDown(widget.def.code);
    }
  }

  void _onTapUp(TapUpDetails _) {
    setState(() => _pressed = false);
    if (!_live) return;
    _live = false;
    if (_deferred) {
      widget.onKeyTapWithMods(widget.def.code); // combo path (D-10)
    } else {
      widget.onKeyUp(widget.def.code); // stops autorepeat instantly
    }
  }

  void _onTapCancel() {
    setState(() => _pressed = false);
    if (!_live) return;
    _live = false;
    // A canceled non-deferred press MUST still release the held key; a
    // canceled deferred press simply never fires its combo.
    if (!_deferred) widget.onKeyUp(widget.def.code);
  }

  @override
  void dispose() {
    // CR-01: a cap disposed mid-hold — a screen pop with a key held, a swipe
    // to another pad, or the docked panel collapsing while a key is down —
    // must still release its held key, else the server key stays down and
    // Windows autorepeats it forever. A deferred press owes a combo (fired
    // only on a real release), not an up, so it releases nothing. The shared
    // owner's keyUp() remove() guard makes this idempotent with the
    // surface-level flush and the D-12 disconnect wipe.
    if (_live && !_deferred) widget.onKeyUp(widget.def.code);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _pressed;
    final borderColor = active ? kAccent : kHairline;
    final faceColor = !widget.enabled
        ? kMuted
        : active
            ? kAccent
            : kText;

    final Widget face = widget.def.icon != null
        ? Icon(widget.def.icon, size: widget.iconSize, color: faceColor)
        : Text(
            widget.def.label!,
            style: TextStyle(
              color: faceColor,
              fontSize: widget.labelSize,
              fontWeight: widget.labelWeight,
            ),
          );

    final cap = GestureDetector(
      key: ValueKey('cap-${widget.def.code}'),
      onTapDown: widget.enabled ? _onTapDown : null,
      // Release handlers are ALWAYS wired (IN-04): a mid-press `enabled`
      // flip used to null these out, swallowing the up and leaving the key
      // held server-side (stuck-key). Only the press ENTRY is
      // permission-gated; the _live guard keeps disabled-started presses
      // inert.
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: Container(
        width: widget.width,
        // The HEIGHT floor is fixed at 48 and never relaxes — it is what
        // keeps every cap tappable. Only [minWidth] is call-site relaxable
        // (UI-SPEC §Spacing exceptions: the Type pad's 7-across slim row).
        constraints: BoxConstraints(minWidth: widget.minWidth, minHeight: 48),
        padding: widget.padding,
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: face,
      ),
    );

    return widget.def.tooltip != null
        ? Tooltip(message: widget.def.tooltip!, child: cap)
        : cap;
  }
}

