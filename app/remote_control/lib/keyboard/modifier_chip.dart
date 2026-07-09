/// One sticky-modifier chip (KEY-03, D-10) — the glanceable armed/locked
/// two-level read (UI-SPEC modifier-chip state table).
///
/// Widget-only and FSM-agnostic: the panel owns the [ModifierFsm], polls
/// [ModifierFsm.stateOf] after each event it drives, and rebuilds the chips
/// with the new [state]. Solid accent fill (locked) vs accent outline
/// (armed) is the deliberate two-level distinction D-10 requires; all
/// transitions animate 200ms ease (the Phase-3 header-chip motion).
library;

import 'package:flutter/material.dart';

import 'modifier_fsm.dart';

const Color _kFill = Color(0xFF16181D);
const Color _kBorderRest = Color(0xFF2A2D34);
const Color _kAccent = Color(0xFF4C8DFF);
const Color _kText = Color(0xFFE6E8EB);
const Color _kMuted = Color(0xFF6B7280);
const Color _kInk = Color(0xFF0E0F12);

/// A modifier chip. See the library doc for the visual contract.
class ModifierChip extends StatelessWidget {
  /// "Ctrl" / "Alt" / "Shift" / "Win" (UI-SPEC copywriting).
  final String label;

  /// The FSM state driving the rest/armed/locked visual.
  final ModifierState state;

  /// False renders the gated muted, non-interactive state.
  final bool enabled;

  /// Tap: arm / disarm / unlock (the panel drives the FSM).
  final VoidCallback onTap;

  /// Long-press: lock (a real server-side hold, D-10).
  final VoidCallback onLongPress;

  /// Creates the chip.
  const ModifierChip({
    super.key,
    required this.label,
    required this.state,
    required this.enabled,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final locked = enabled && state == ModifierState.locked;
    final armed = enabled && state == ModifierState.armed;

    final Color fill = locked ? _kAccent : _kFill;
    final Color border = locked
        ? _kAccent
        : armed
            ? _kAccent
            : _kBorderRest;
    final Color labelColor = !enabled
        ? _kMuted
        : locked
            ? _kInk
            : armed
                ? _kAccent
                : _kText;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 4), // xs gap after the label
              const Icon(Icons.lock, size: 16, color: _kInk),
            ],
          ],
        ),
      ),
    );
  }
}
