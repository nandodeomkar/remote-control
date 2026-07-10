/// Toggleable special-key rows (KEY-02/KEY-04, D-09/D-11) + the group
/// switcher + the client half of the locked `key.code` vocabulary.
///
/// Widget-only and service-agnostic (mouse_buttons house style): key presses
/// surface through injected callbacks, so the widget test needs no service
/// fake. The keyboard panel (04-06 Task 3) wires the callbacks to
/// `service.sendReliable(KeyMsg(...))` and the haptic tick.
///
/// # Key-cap emission model (D-11 + D-10 interplay, plan-locked)
///
/// On press-down — if NO armed modifiers are pending — the cap emits
/// [KeyRows.onKeyDown] immediately; release emits [KeyRows.onKeyUp]. A quick
/// press is a down/up pair (≈ tap); a HOLD leaves the key down so WINDOWS
/// autorepeats until the up (KEY-04 — server-side repeat, never client
/// tap-spam). If armed mods ARE pending at press-down, the cap defers and
/// emits [KeyRows.onKeyTapWithMods] on release instead — the combo path
/// (`key {action: tap, mods: [...]}`), after which the panel auto-resets the
/// armed chips (D-10).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/device_store.dart';

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
];

/// The visible special-key row group (D-09 — toggleable, default Nav).
enum KeyRowGroup {
  /// Esc/Tab/Home/End/PgUp/PgDn/Del + the inverted-T arrows (default).
  nav,

  /// F1..F12.
  fn,

  /// The 3-column numpad + Enter + decimal.
  num,
}

/// The shared_preferences key holding the selected row group (D-09).
const String kKeyRowGroupPrefsKey = 'keyboard.rowGroup';

/// Typed store for the row-group selection over the [PrefsKv] seam
/// (non-secret by rule — never secure storage; sensitivity house pattern).
class KeyRowGroupStore {
  final PrefsKv _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  KeyRowGroupStore({PrefsKv? prefs}) : _prefs = prefs ?? SharedPrefsKv();

  /// The persisted group; [KeyRowGroup.nav] when unset, unknown, or when
  /// the platform read fails (a broken prefs read must never take the
  /// keyboard down — the default group is always available).
  Future<KeyRowGroup> load() async {
    try {
      final stored = await _prefs.getString(kKeyRowGroupPrefsKey);
      return KeyRowGroup.values.firstWhere(
        (group) => group.name == stored,
        orElse: () => KeyRowGroup.nav,
      );
    } on Object {
      return KeyRowGroup.nav;
    }
  }

  /// Persists [group] (its enum name: 'nav' | 'fn' | 'num') under
  /// [kKeyRowGroupPrefsKey].
  Future<void> save(KeyRowGroup group) =>
      _prefs.setString(kKeyRowGroupPrefsKey, group.name);
}

/// The [KeyRowGroupStore] singleton (overridable in tests).
final keyRowGroupStoreProvider = Provider<KeyRowGroupStore>(
  (ref) => KeyRowGroupStore(),
);

/// Riverpod 3 unified [Notifier] over the selection: synchronous
/// [KeyRowGroup.nav] seed (D-09 default), async load on build,
/// persist-through on [set].
class KeyRowGroupNotifier extends Notifier<KeyRowGroup> {
  @override
  KeyRowGroup build() {
    // Seed synchronously with the D-09 default so the first frame renders;
    // replace with the persisted value as soon as it loads.
    unawaited(_load(ref.watch(keyRowGroupStoreProvider)));
    return KeyRowGroup.nav;
  }

  Future<void> _load(KeyRowGroupStore store) async {
    state = await store.load();
  }

  /// Selects [group], applying live and persisting immediately
  /// (fire-and-forget — a failed prefs write costs persistence only).
  void set(KeyRowGroup group) {
    state = group;
    unawaited(ref.read(keyRowGroupStoreProvider).save(group));
  }
}

/// The persisted row-group selection the panel's switcher edits.
final keyRowGroupProvider = NotifierProvider<KeyRowGroupNotifier, KeyRowGroup>(
  KeyRowGroupNotifier.new,
);

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

/// Nav cluster caps (wrapping grid — the arrows render separately as the
/// inverted-T via [kNavArrowCaps]).
const List<KeyCapDef> kNavClusterCaps = [
  KeyCapDef('Esc', label: 'Esc'),
  KeyCapDef('Tab', label: 'Tab'),
  KeyCapDef('Home', label: 'Home'),
  KeyCapDef('End', label: 'End'),
  KeyCapDef('PgUp', label: 'PgUp'),
  KeyCapDef('PgDn', label: 'PgDn'),
  KeyCapDef('Del', label: 'Del'),
];

/// The four arrow caps (inverted-T: Up above Left/Down/Right).
const List<KeyCapDef> kNavArrowCaps = [
  KeyCapDef('Up', icon: Icons.arrow_upward, tooltip: 'Up'),
  KeyCapDef('Left', icon: Icons.arrow_back, tooltip: 'Left'),
  KeyCapDef('Down', icon: Icons.arrow_downward, tooltip: 'Down'),
  KeyCapDef('Right', icon: Icons.arrow_forward, tooltip: 'Right'),
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

/// Every cap definition a [group] renders (the widget-test coverage seam).
List<KeyCapDef> capsForGroup(KeyRowGroup group) => switch (group) {
      KeyRowGroup.nav => [...kNavClusterCaps, ...kNavArrowCaps],
      KeyRowGroup.fn => kFnCaps,
      KeyRowGroup.num => kNumCaps,
    };

// ── Widgets ────────────────────────────────────────────────────────────────

const Color _kCapFill = Color(0xFF16181D);
const Color _kBorderRest = Color(0xFF2A2D34);
const Color _kAccent = Color(0xFF4C8DFF);
const Color _kText = Color(0xFFE6E8EB);
const Color _kMuted = Color(0xFF6B7280);

/// The active group's key caps. See the library doc for the emission model.
class KeyRows extends StatelessWidget {
  /// Which row group renders.
  final KeyRowGroup group;

  /// False renders the gated all-muted, non-interactive state.
  final bool enabled;

  /// Press-down with no armed mods: `key {action: down}` (KEY-04 hold).
  final void Function(String code) onKeyDown;

  /// Release of a non-deferred press: `key {action: up}` (stops autorepeat).
  final void Function(String code) onKeyUp;

  /// Release of a DEFERRED press (armed mods were pending at press-down):
  /// the combo path — `key {action: tap, mods: [...]}` (D-10).
  final void Function(String code) onKeyTapWithMods;

  /// Whether armed modifiers are pending — polled at press-down to pick the
  /// down/up vs tap+mods branch (the panel wires this to the FSM).
  final bool Function() hasArmedMods;

  /// Fired on every press-down (the panel wires the haptic tick here —
  /// UI-SPEC: tick on key-down, not release).
  final VoidCallback? onPressHaptic;

  /// Creates the rows.
  const KeyRows({
    super.key,
    required this.group,
    required this.enabled,
    required this.onKeyDown,
    required this.onKeyUp,
    required this.onKeyTapWithMods,
    required this.hasArmedMods,
    this.onPressHaptic,
  });

  Widget _cap(KeyCapDef def, {double? width}) => _KeyCap(
        def: def,
        enabled: enabled,
        width: width,
        onKeyDown: onKeyDown,
        onKeyUp: onKeyUp,
        onKeyTapWithMods: onKeyTapWithMods,
        hasArmedMods: hasArmedMods,
        onPressHaptic: onPressHaptic,
      );

  @override
  Widget build(BuildContext context) {
    switch (group) {
      case KeyRowGroup.nav:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [for (final def in kNavClusterCaps) _cap(def)],
            ),
            const SizedBox(height: 8),
            // Inverted-T: Up above Left/Down/Right (muscle memory).
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _cap(kNavArrowCaps[0], width: 64), // Up
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _cap(kNavArrowCaps[1], width: 64), // Left
                    const SizedBox(width: 8),
                    _cap(kNavArrowCaps[2], width: 64), // Down
                    const SizedBox(width: 8),
                    _cap(kNavArrowCaps[3], width: 64), // Right
                  ],
                ),
              ],
            ),
          ],
        );
      case KeyRowGroup.fn:
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [for (final def in kFnCaps) _cap(def, width: 56)],
        );
      case KeyRowGroup.num:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var row = 0; row < 4; row++) ...[
              if (row > 0) const SizedBox(height: 8),
              Row(
                children: [
                  for (var col = 0; col < 3; col++) ...[
                    if (col > 0) const SizedBox(width: 8),
                    Expanded(child: _cap(kNumCaps[row * 3 + col])),
                  ],
                ],
              ),
            ],
          ],
        );
    }
  }
}

/// One key cap: press-down branch capture + pressed accent state
/// (UI-SPEC key-cap state table).
class _KeyCap extends StatefulWidget {
  final KeyCapDef def;
  final bool enabled;
  final double? width;
  final void Function(String code) onKeyDown;
  final void Function(String code) onKeyUp;
  final void Function(String code) onKeyTapWithMods;
  final bool Function() hasArmedMods;
  final VoidCallback? onPressHaptic;

  const _KeyCap({
    required this.def,
    required this.enabled,
    required this.onKeyDown,
    required this.onKeyUp,
    required this.onKeyTapWithMods,
    required this.hasArmedMods,
    this.width,
    this.onPressHaptic,
  });

  @override
  State<_KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<_KeyCap> {
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
  Widget build(BuildContext context) {
    final active = widget.enabled && _pressed;
    final borderColor = active ? _kAccent : _kBorderRest;
    final faceColor = !widget.enabled
        ? _kMuted
        : active
            ? _kAccent
            : _kText;

    final Widget face = widget.def.icon != null
        ? Icon(widget.def.icon, size: 20, color: faceColor)
        : Text(
            widget.def.label!,
            style: TextStyle(
              color: faceColor,
              fontSize: 14,
              fontWeight: FontWeight.w400,
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
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _kCapFill,
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

/// The 3-segment Nav/Fn/Num group switcher (UI-SPEC: selected = accent label
/// + accent underline, unselected muted, 12/400, ≥48px tall). Persistence is
/// the caller's job ([keyRowGroupProvider] in the panel).
class KeyRowGroupSwitcher extends StatelessWidget {
  /// The selected group.
  final KeyRowGroup group;

  /// Fired with the newly selected group.
  final ValueChanged<KeyRowGroup> onChanged;

  /// Creates the switcher.
  const KeyRowGroupSwitcher({
    super.key,
    required this.group,
    required this.onChanged,
  });

  static const _labels = {
    KeyRowGroup.nav: 'Nav',
    KeyRowGroup.fn: 'Fn',
    KeyRowGroup.num: 'Num',
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final g in KeyRowGroup.values)
          Expanded(
            child: InkWell(
              onTap: () => onChanged(g),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: g == group ? _kAccent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  _labels[g]!,
                  style: TextStyle(
                    color: g == group ? _kAccent : _kMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
