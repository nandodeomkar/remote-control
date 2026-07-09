/// Pure sticky-modifier FSM (KEY-03, D-10/D-12) — no Flutter, no IO.
///
/// Per-modifier state machine over {ctrl, alt, shift, win} in the
/// reconnect_fsm house style: events in, effects out, the driver (the
/// keyboard panel) executes every effect. This class holds no timers, no
/// channel, and imports nothing from Flutter or the IO libraries.
///
/// # Why LOCKED is a physical hold, never the `mods` array (Pitfall 7)
///
/// The `key {action: down/up}` autorepeat path carries NO `mods` — the
/// server's `key_down`/`key_up` take only a code. If a locked modifier rode
/// the `mods` array, a held key with Ctrl locked would repeat as the bare
/// key (Ctrl+Right repeating as Right). So a LOCKED modifier is its own held
/// key — `key {code: ControlLeft/AltLeft/ShiftLeft/WinLeft, action: down}`
/// on lock, `action: up` on tap-off — making the OS itself chord every
/// repeat. CONN-07 release_all + [disconnected] (D-12) clean it up after a
/// drop.
///
/// ARMED (tap) modifiers are the opposite: client-local only, riding the
/// `mods` array of the next non-modifier `tap` and auto-resetting (D-10).
/// A locked modifier is deliberately EXCLUDED from [modsForTap] — it is
/// already physically held server-side; listing it too would double-apply.
///
/// The widget layer polls [stateOf] after each event it drives (the chips
/// are the only caller) — no change stream by design.
library;

/// The four sticky modifiers (UI-SPEC chips: Ctrl / Alt / Shift / Win).
enum Mod {
  /// Ctrl.
  ctrl,

  /// Alt.
  alt,

  /// Shift.
  shift,

  /// The Windows key.
  win,
}

/// Per-modifier state (UI-SPEC chip state table).
enum ModifierState {
  /// Inactive.
  rest,

  /// Tap-armed: rides the next non-modifier tap's `mods`, then auto-resets.
  armed,

  /// Long-press-locked: a REAL held key server-side (see library doc).
  locked,
}

/// The `key.code` each modifier holds with when LOCKED — mirrors the
/// keymap.rs `CLIENT_KEY_CODES` modifier hold codes byte-for-byte.
const Map<Mod, String> kModifierHoldCodes = {
  Mod.ctrl: 'ControlLeft',
  Mod.alt: 'AltLeft',
  Mod.shift: 'ShiftLeft',
  Mod.win: 'WinLeft',
};

/// The wire `mods` array string for each modifier (json_codec KeyMsg mods).
const Map<Mod, String> _kWireMods = {
  Mod.ctrl: 'ctrl',
  Mod.alt: 'alt',
  Mod.shift: 'shift',
  Mod.win: 'win',
};

/// An effect the driver must execute (send on the reliable path).
sealed class ModifierEffect {
  const ModifierEffect();
}

/// Send `key {code: holdCode, action: down}` — a lock became a physical hold.
final class SendModifierDown extends ModifierEffect {
  /// The keymap.rs hold code (e.g. `ControlLeft`).
  final String holdCode;

  /// Creates the effect.
  const SendModifierDown(this.holdCode);
}

/// Send `key {code: holdCode, action: up}` — a lock was tapped off.
final class SendModifierUp extends ModifierEffect {
  /// The keymap.rs hold code (e.g. `ControlLeft`).
  final String holdCode;

  /// Creates the effect.
  const SendModifierUp(this.holdCode);
}

/// The sticky-modifier FSM. See the library doc for the model.
class ModifierFsm {
  final Map<Mod, ModifierState> _states = {
    for (final mod in Mod.values) mod: ModifierState.rest,
  };

  /// Armed modifiers in tap order (chording: Ctrl then Alt taps produce
  /// `['ctrl', 'alt']` on the next combo).
  final List<Mod> _armedOrder = [];

  /// Chip tap: rest -> armed, armed -> rest (both client-local, no effects);
  /// locked -> rest releasing the physical hold ([SendModifierUp]).
  List<ModifierEffect> tap(Mod mod) {
    switch (_states[mod]!) {
      case ModifierState.rest:
        _states[mod] = ModifierState.armed;
        _armedOrder.add(mod);
        return const [];
      case ModifierState.armed:
        _states[mod] = ModifierState.rest;
        _armedOrder.remove(mod);
        return const [];
      case ModifierState.locked:
        _states[mod] = ModifierState.rest;
        return [SendModifierUp(kModifierHoldCodes[mod]!)];
    }
  }

  /// Chip long-press: rest/armed -> locked, starting the physical hold
  /// ([SendModifierDown]); already-locked is idempotent (never a second
  /// down — the server would autorepeat the extra press).
  List<ModifierEffect> longPress(Mod mod) {
    switch (_states[mod]!) {
      case ModifierState.rest:
      case ModifierState.armed:
        _armedOrder.remove(mod); // upgrade: leaves the mods array
        _states[mod] = ModifierState.locked;
        return [SendModifierDown(kModifierHoldCodes[mod]!)];
      case ModifierState.locked:
        return const [];
    }
  }

  /// A non-modifier key tap was sent: every ARMED modifier auto-resets to
  /// rest (D-10 — it rode that tap's `mods`); locked ones stay locked. No
  /// effects — the arm was client-local.
  List<ModifierEffect> onNonModifierTap() {
    for (final mod in _armedOrder) {
      _states[mod] = ModifierState.rest;
    }
    _armedOrder.clear();
    return const [];
  }

  /// D-12: the connection dropped — ALL state to rest with ZERO effects.
  ///
  /// The socket is gone: CONN-07 release_all already freed the real held
  /// keys server-side, and sending ups into a dead (or worse, a NEW) session
  /// would be wrong.
  List<ModifierEffect> disconnected() {
    for (final mod in Mod.values) {
      _states[mod] = ModifierState.rest;
    }
    _armedOrder.clear();
    return const [];
  }

  /// The current state of [mod] (the chips poll this after each event).
  ModifierState stateOf(Mod mod) => _states[mod]!;

  /// The `mods` array for the next non-modifier tap: ARMED modifiers only,
  /// in tap order. Locked modifiers are excluded — they are already
  /// physically held server-side (Pitfall 7 double-apply avoidance).
  List<String> modsForTap() =>
      _armedOrder.map((mod) => _kWireMods[mod]!).toList();
}
