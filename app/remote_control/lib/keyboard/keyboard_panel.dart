/// KeyboardPanel — the expandable panel over the trackpad (04-05 Task 3,
/// D-07).
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
/// The [rows] slot is a placeholder this plan; 04-06 fills it with the
/// modifier-chip row, group switcher, and special-key rows (D-09/D-10).
library;

import 'package:flutter/material.dart';

import 'diff_ops.dart';
import 'hidden_text_input.dart';

/// The expandable keyboard panel shell (D-07).
class KeyboardPanel extends StatefulWidget {
  /// Whether the panel is open (chrome visible, IME raised).
  final bool expanded;

  /// The hidden field's focus node — focusing it raises the system IME.
  final FocusNode imeFocusNode;

  /// The committed-text diff producer feeding the reliable path.
  final ImeDiffProducer producer;

  /// 04-06 slot: modifier chips + group switcher + key rows land here.
  final Widget? rows;

  /// Creates the panel.
  const KeyboardPanel({
    super.key,
    required this.expanded,
    required this.imeFocusNode,
    required this.producer,
    this.rows,
  });

  @override
  State<KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends State<KeyboardPanel> {
  @override
  void initState() {
    super.initState();
    if (widget.expanded) {
      // Post-frame: the field must be attached before it can take focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.expanded) widget.imeFocusNode.requestFocus();
      });
    }
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
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ALWAYS mounted (both states): a 1x1 invisible sliver outside the
        // animating chrome, so toggling never detaches the IME connection.
        HiddenTextInput(
          producer: widget.producer,
          focusNode: widget.imeFocusNode,
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
                  child: widget.rows ??
                      const Column(mainAxisSize: MainAxisSize.min),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}
