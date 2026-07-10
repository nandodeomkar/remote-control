/// KeyboardPanel — the expandable panel over the trackpad (04-05 shell,
/// D-07; rows filled in 04-06: KEY-02/KEY-03/KEY-04).
///
/// NOT a separate screen: it docks at the bottom of the trackpad screen
/// Column (trackpad -> L/M/R bar -> panel -> system IME) and slides
/// open/closed in 200ms ease. The trackpad shrinks above it and stays live
/// for cursor movement while typing.
///
/// The [HiddenTextInput] is mounted in BOTH states — only the chrome height
/// animates — so the Android input connection survives toggling (Pitfall 6).
/// Expanding requests focus on [imeFocusNode] (raises the system IME);
/// collapsing unfocuses (lowers it).
///
/// # The rows (04-06): chips + switcher + active key row
///
/// Top→bottom per UI-SPEC: the four-chip modifier row (Ctrl/Alt/Shift/Win),
/// lg gap, the Nav/Fn/Num group switcher, then the active [KeyRows]. The
/// panel owns ONE [ModifierFsm] and wires every emission path onto the
/// reliable channel through the injected [send] seam:
///
/// - chip tap/long-press -> FSM events; every [SendModifierDown]/
///   [SendModifierUp] effect becomes `key {code: holdCode, action: down/up}`
///   (D-10: LOCKED = physical hold, so held-key combos autorepeat);
/// - key-cap down/up -> `key {action: down/up}` (KEY-04 autorepeat rides the
///   server hold);
/// - key-cap tap+mods -> `key {action: tap, mods: modsForTap()}` then
///   [ModifierFsm.onNonModifierTap] so armed chips visually auto-reset.
///
/// Chip/row rebuilds ride a panel-local setState — NEVER the trackpad
/// surface (the panel subtree is isolated from the Listener per 04-05).
///
/// # D-12 reset on disconnect
///
/// On the transition INTO disconnected (detected off the injected [changes]
/// ping stream + [isDisconnected] probe — the service seams, injectable so
/// the widget test drives a fake stream), the panel calls
/// [ModifierFsm.disconnected] (zero effects — the socket is gone; CONN-07
/// release_all already freed the real keys), forgets ALL held key caps so
/// no stale `up` is ever flushed into a NEW session, and fires the CR-01
/// IME reset tick so the hidden field atomically reseeds its diff producer
/// AND controller to the sentinel — pre-disconnect typed text can never
/// replay after reconnect (T-04-03). No phantom input survives a drop.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import 'diff_ops.dart';
import 'hidden_text_input.dart';
import 'key_rows.dart';
import 'modifier_chip.dart';
import 'modifier_fsm.dart';

/// The expandable keyboard panel (D-07 shell + the 04-06 rows).
class KeyboardPanel extends ConsumerStatefulWidget {
  /// Whether the panel is open (chrome visible, IME raised).
  final bool expanded;

  /// The hidden field's focus node — focusing it raises the system IME.
  final FocusNode imeFocusNode;

  /// The committed-text diff producer feeding the reliable path.
  final ImeDiffProducer producer;

  /// False renders chips + caps gated (muted, inert — "muted, not red").
  final bool enabled;

  /// The reliable-path seam: the screen wires `service.sendReliable`.
  final void Function(RemoteMessage msg) send;

  /// The service `changes` ping stream (state-affecting transitions only).
  final Stream<void> changes;

  /// Probed on each [changes] ping: true when the chip status is
  /// disconnected. The false->true transition triggers the D-12 reset.
  final bool Function() isDisconnected;

  /// Creates the panel.
  const KeyboardPanel({
    super.key,
    required this.expanded,
    required this.imeFocusNode,
    required this.producer,
    required this.enabled,
    required this.send,
    required this.changes,
    required this.isDisconnected,
  });

  @override
  ConsumerState<KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends ConsumerState<KeyboardPanel> {
  /// The ONE sticky-modifier FSM (chips poll stateOf after each event).
  final ModifierFsm _fsm = ModifierFsm();

  /// The key caps currently held down server-side (each sent a `down` whose
  /// `up` is still owed). Multiple caps can be concurrently held — rollover
  /// between arrow keys is the normal pattern (CR-02): each _KeyCap has its
  /// own GestureDetector and pointers are tracked independently. Cleared
  /// WITHOUT ups on disconnect (D-12) — CONN-07 release_all already freed
  /// the real keys and queued stale ups must never leak into a new session.
  final Set<String> _heldCodes = <String>{};

  /// D-12 transition detection off the changes pings.
  StreamSubscription<void>? _changesSub;
  bool _wasDisconnected = false;

  /// The CR-01 atomic-IME-wipe trigger: incrementing it makes the
  /// [HiddenTextInput] purge pre-disconnect typed text (potentially a
  /// password) from BOTH the diff baseline and the controller buffer in one
  /// synchronous callback, so no post-reconnect diff can replay it through
  /// sendReliable (T-04-03).
  final ValueNotifier<int> _imeResetTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    if (widget.expanded) {
      // Post-frame: the field must be attached before it can take focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.expanded) widget.imeFocusNode.requestFocus();
      });
    }

    _wasDisconnected = widget.isDisconnected();
    _changesSub = widget.changes.listen((_) {
      final disconnected = widget.isDisconnected();
      if (disconnected && !_wasDisconnected) _onDisconnected();
      _wasDisconnected = disconnected;
    });
  }

  /// D-12: reset all armed/locked chips (zero send effects — the FSM
  /// guarantees it), forget ALL held caps so their ups are skipped, and fire
  /// the CR-01 IME wipe so the hidden field's producer + controller both
  /// return to the sentinel atomically.
  void _onDisconnected() {
    _fsm.disconnected();
    _heldCodes.clear();
    _imeResetTick.value++;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(KeyboardPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        widget.imeFocusNode.requestFocus();
      } else {
        widget.imeFocusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _imeResetTick.dispose();
    super.dispose();
  }

  // ── Wiring: FSM effects + key-cap emissions -> the reliable path ─────────

  void _sendEffects(List<ModifierEffect> effects) {
    for (final effect in effects) {
      switch (effect) {
        case SendModifierDown(:final holdCode):
          widget.send(KeyMsg(code: holdCode, action: 'down'));
        case SendModifierUp(:final holdCode):
          widget.send(KeyMsg(code: holdCode, action: 'up'));
      }
    }
  }

  void _onChipTap(Mod mod) {
    unawaited(HapticFeedback.lightImpact());
    _sendEffects(_fsm.tap(mod));
    setState(() {});
  }

  void _onChipLongPress(Mod mod) {
    unawaited(HapticFeedback.lightImpact());
    _sendEffects(_fsm.longPress(mod));
    setState(() {});
  }

  void _onKeyDown(String code) {
    _heldCodes.add(code);
    widget.send(KeyMsg(code: code, action: 'down'));
  }

  void _onKeyUp(String code) {
    // Only release a key whose down survived: remove() returning false
    // covers both the D-12 disconnect wipe (the server already released)
    // AND releases forwarded by the always-wired cap handlers when no down
    // ever fired (IN-04).
    if (!_heldCodes.remove(code)) return;
    widget.send(KeyMsg(code: code, action: 'up'));
  }

  void _onKeyTapWithMods(String code) {
    widget.send(KeyMsg(code: code, action: 'tap', mods: _fsm.modsForTap()));
    _fsm.onNonModifierTap();
    setState(() {}); // armed chips visually auto-reset (D-10)
  }

  static const _chipMods = [
    (Mod.ctrl, 'Ctrl'),
    (Mod.alt, 'Alt'),
    (Mod.shift, 'Shift'),
    (Mod.win, 'Win'),
  ];

  Widget _rows() {
    final group = ref.watch(keyRowGroupProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Modifier-chip row (UI-SPEC: top of the panel, sm gaps).
        Row(
          children: [
            for (final (mod, label) in _chipMods) ...[
              if (mod != Mod.ctrl) const SizedBox(width: 8),
              Expanded(
                child: ModifierChip(
                  label: label,
                  state: _fsm.stateOf(mod),
                  enabled: widget.enabled,
                  onTap: () => _onChipTap(mod),
                  onLongPress: () => _onChipLongPress(mod),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24), // lg gap (UI-SPEC)
        KeyRowGroupSwitcher(
          group: group,
          onChanged: ref.read(keyRowGroupProvider.notifier).set,
        ),
        const SizedBox(height: 8),
        KeyRows(
          group: group,
          enabled: widget.enabled,
          onKeyDown: _onKeyDown,
          onKeyUp: _onKeyUp,
          onKeyTapWithMods: _onKeyTapWithMods,
          hasArmedMods: () => _fsm.modsForTap().isNotEmpty,
          onPressHaptic: HapticFeedback.lightImpact,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ALWAYS mounted (both states): a 1x1 invisible sliver outside the
        // animating chrome, so toggling never detaches the IME connection.
        HiddenTextInput(
          producer: widget.producer,
          focusNode: widget.imeFocusNode,
          resetSignal: _imeResetTick,
        ),

        // The animating chrome: 200ms ease slide between zero height and
        // the intrinsic panel height.
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
          alignment: Alignment.topCenter,
          child: widget.expanded
              ? Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    // Continuous with the trackpad above.
                    color: Color(0xFF0E0F12),
                    border: Border(
                      top: BorderSide(color: Color(0xFF2A2D34)),
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: _rows(),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}
