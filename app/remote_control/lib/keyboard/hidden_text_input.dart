/// HiddenTextInput — zero-footprint IME capture (04-05 Task 2, D-08).
///
/// An offscreen system [TextField] that exists only to raise the device IME
/// and feed committed-text transitions to the [ImeDiffProducer]. It has NO
/// visual contract: 1x1 logical px, opacity 0, pointer-transparent, no
/// caret/selection/background — the user never sees it.
///
/// Pitfall 6 (RESEARCH): this field's focus is what raises the system IME.
/// The panel drives the provided [FocusNode]; special-key surfaces must
/// never steal it. Do NOT wrap this in Offstage or
/// Visibility(maintainState: false) — those detach the input connection on
/// Android and the IME never rises.
///
/// SPEC section 12 redaction: [ExcludeSemantics] keeps typed content out of
/// the accessibility tree; nothing here logs text (threat T-04-03).
library;

import 'package:flutter/material.dart';

import 'diff_ops.dart';

/// The invisible IME-attached field. Focusable, never visible.
class HiddenTextInput extends StatefulWidget {
  /// Receives committed-text transitions (diff -> TextMsg).
  final ImeDiffProducer producer;

  /// Owned by the panel/screen — focusing it raises the system IME.
  final FocusNode focusNode;

  /// Creates the hidden input.
  const HiddenTextInput({
    super.key,
    required this.producer,
    required this.focusNode,
  });

  @override
  State<HiddenTextInput> createState() => _HiddenTextInputState();
}

class _HiddenTextInputState extends State<HiddenTextInput> {
  late final TextEditingController _controller;

  /// Re-entrancy guard: true while the reseed write-back is in flight so a
  /// spurious onChanged from the programmatic write never emits a diff.
  bool _reseeding = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.producer.seedText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (_reseeding) return;
    widget.producer.onChanged(value);
    if (widget.producer.needsReseed(value)) {
      final seed = widget.producer.reseed();
      _reseeding = true;
      _controller.value = TextEditingValue(
        text: seed,
        selection: TextSelection.collapsed(offset: seed.length),
      );
      _reseeding = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Visually absent but focusable and IME-attached: 1x1 box + opacity 0 +
    // IgnorePointer. NEVER Offstage/Visibility(maintainState:false) — they
    // detach the Android input connection (Pitfall 6).
    return ExcludeSemantics(
      child: SizedBox(
        width: 1,
        height: 1,
        child: Opacity(
          opacity: 0,
          child: IgnorePointer(
            child: TextField(
              controller: _controller,
              focusNode: widget.focusNode,
              onChanged: _onChanged,
              // Typing fidelity (D-08 rides the system IME):
              keyboardType: TextInputType.multiline,
              maxLines: null, // IME Enter inserts '\n' -> flows as ins text.
              autocorrect: true,
              enableSuggestions: true,
              textCapitalization: TextCapitalization.none,
              // Smart substitutions would silently rewrite what the PC gets.
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              autofillHints: null,
              // No visual contract: no caret, no selection, no decoration.
              showCursor: false,
              enableInteractiveSelection: false,
              decoration: null,
              style: const TextStyle(fontSize: 1, color: Colors.transparent),
            ),
          ),
        ),
      ),
    );
  }
}
