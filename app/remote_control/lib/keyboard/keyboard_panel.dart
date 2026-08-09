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
/// lg gap, the group switcher, then the active key row.
///
/// # The stuck-key model is NOT owned here (D-95)
///
/// Every emission path — chip tap/long-press, key-cap down/up, key-cap
/// tap+mods, the D-12 disconnect reset, the CR-01 IME wipe and the LIVE-only
/// dispose flush — belongs to the shared [KeyboardInputController], which this
/// State constructs in `initState` and disposes in `dispose()`. The full-screen
/// keyboard constructs the SAME class, so the two surfaces cannot drift: a fix
/// there lands here by construction. This file only supplies the seams
/// ([send] / [changes] / [isDisconnected]) and the layout.
///
/// Chip/row rebuilds ride a panel-local setState — NEVER the trackpad
/// surface (the panel subtree is isolated from the Listener per 04-05).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../settings/haptics.dart';
import '../theme/tokens.dart';
import 'diff_ops.dart';
import 'hidden_text_input.dart';
import 'key_rows.dart';
import 'keyboard_input_controller.dart';
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
  /// The shared stuck-key owner (D-95) — the SAME class the full-screen
  /// keyboard constructs. Built here, disposed here: ownership is lifecycle,
  /// and the panel's teardown moment (the docked child unmounting with the
  /// trackpad screen) is exactly when the LIVE-only flush must fire.
  late final KeyboardInputController _controller;

  @override
  void initState() {
    super.initState();
    if (widget.expanded) {
      // Post-frame: the field must be attached before it can take focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.expanded) widget.imeFocusNode.requestFocus();
      });
    }

    // Forwarding closures, NOT the raw widget fields: the trackpad screen
    // rebuilds this panel with fresh `send` / `isDisconnected` closures on
    // every build, and the owner outlives each of them.
    _controller = KeyboardInputController(
      send: (msg) => widget.send(msg),
      changes: widget.changes,
      isDisconnected: () => widget.isDisconnected(),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
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
    // The owner cancels its subscription and runs the LIVE-only flush — see
    // KeyboardInputController.dispose. Flutter unmounts children before
    // parents, so a held cap has already released through KeyCap.dispose by
    // the time this runs; the remove() guard makes the pair idempotent.
    _controller.dispose();
    super.dispose();
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
                  state: _controller.stateOf(mod),
                  enabled: widget.enabled,
                  onTap: () => _controller.chipTap(mod),
                  onLongPress: () => _controller.chipLongPress(mod),
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
          onKeyDown: _controller.keyDown,
          onKeyUp: _controller.keyUp,
          onKeyTapWithMods: _controller.keyTapWithMods,
          hasArmedMods: _controller.hasArmedMods,
          onPressHaptic: hapticTick,
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
          resetSignal: _controller.imeResetTick,
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
                    color: kBg,
                    border: Border(
                      top: BorderSide(color: kHairline),
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
