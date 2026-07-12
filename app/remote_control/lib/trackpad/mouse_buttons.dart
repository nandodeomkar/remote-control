/// L/M/R on-screen mouse buttons (PAD-02) — the slim 64px bar docked beneath
/// the trackpad surface (UI-SPEC "L/M/R mouse button").
///
/// Widget-only and service-agnostic: presses surface through the injected
/// [MouseButtonsBar.onPress] callback ('left' | 'middle' | 'right' — the
/// ClickMsg button vocabulary), so the widget test needs no service fake.
/// The screen wires `onPress` to `service.sendReliable(ClickMsg(...))` + the
/// haptic tick, and [MouseButtonsBar.enabled] to its transition-only status
/// watch.
///
/// Contract (UI-SPEC): bar bg `#0E0F12`, 64px tall; buttons rest `#16181D`
/// fill + `#2A2D34` 1px border + 8px radius, labels "L"/"M"/"R" 16/600 muted
/// `#6B7280`; L flex 2 / M flex 1 / R flex 2, sm (8px) gaps, md (16px)
/// horizontal bar padding, each button ≥48px tall. Tap-down flashes the
/// accent `#4C8DFF` border + label (momentary, NO easing) and fires onPress
/// immediately (click-on-down, benchmark feel). Disabled (not connected):
/// all-muted, non-interactive ("muted, not red").
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The docked L/M/R button bar. See the library doc for the contract.
class MouseButtonsBar extends StatelessWidget {
  /// Fired on tap-down with 'left' | 'middle' | 'right'.
  final void Function(String button) onPress;

  /// False renders the gated all-muted, non-interactive state.
  final bool enabled;

  /// Creates the bar.
  const MouseButtonsBar({
    super.key,
    required this.onPress,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      color: kBg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: _MouseButton(
              label: 'L',
              tooltip: 'Left click',
              button: 'left',
              enabled: enabled,
              onPress: onPress,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MouseButton(
              label: 'M',
              tooltip: 'Middle click',
              button: 'middle',
              enabled: enabled,
              onPress: onPress,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _MouseButton(
              label: 'R',
              tooltip: 'Right click',
              button: 'right',
              enabled: enabled,
              onPress: onPress,
            ),
          ),
        ],
      ),
    );
  }
}

/// One button: tap-down accent flash (momentary, no easing) + onPress.
class _MouseButton extends StatefulWidget {
  final String label;
  final String tooltip;
  final String button;
  final bool enabled;
  final void Function(String button) onPress;

  const _MouseButton({
    required this.label,
    required this.tooltip,
    required this.button,
    required this.enabled,
    required this.onPress,
  });

  @override
  State<_MouseButton> createState() => _MouseButtonState();
}

class _MouseButtonState extends State<_MouseButton> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    setState(() => _pressed = true);
    // Click on touch-down (benchmark feel — a mouse button acts on press).
    widget.onPress(widget.button);
  }

  void _release() {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _pressed;
    final borderColor = active ? kAccent : kHairline;
    final labelColor = active ? kAccent : kMuted;

    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: widget.enabled ? _onTapDown : null,
        onTapUp: widget.enabled ? (_) => _release() : null,
        onTapCancel: widget.enabled ? _release : null,
        child: Container(
          // Fills the padded 64px bar -> 48px tall (the touch-target floor).
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: kSurface,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              color: labelColor,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
