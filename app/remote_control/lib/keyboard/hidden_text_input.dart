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

  /// Fired by the owner on the disconnected transition. The State answers
  /// with an ATOMIC producer-reseed + controller write-back: both the diff
  /// baseline and the controller buffer return to [kImeSentinel] in the same
  /// synchronous callback, purging pre-disconnect typed text (possibly a
  /// password) so no post-reconnect diff can replay it (CR-01 / T-04-03).
  final Listenable? resetSignal;

  /// Creates the hidden input.
  const HiddenTextInput({
    super.key,
    required this.producer,
    required this.focusNode,
    this.resetSignal,
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
    widget.resetSignal?.addListener(_onExternalReset);
  }

  @override
  void didUpdateWidget(HiddenTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-subscribe when the signal identity changes — a stale subscription
    // on a replaced notifier would silently drop resets (IN-05-class hazard).
    if (!identical(widget.resetSignal, oldWidget.resetSignal)) {
      oldWidget.resetSignal?.removeListener(_onExternalReset);
      widget.resetSignal?.addListener(_onExternalReset);
    }
  }

  @override
  void dispose() {
    widget.resetSignal?.removeListener(_onExternalReset);
    _controller.dispose();
    super.dispose();
  }

  /// CR-01 / T-04-03: the owner saw the disconnected transition. Reseed the
  /// producer AND write the seed back into the controller in this ONE
  /// synchronous callback — `producer.reseed()` resets the committed text to
  /// the sentinel and returns the seed, so the two sides can never desync.
  /// The [_reseeding] guard mirrors the boundary-reseed write-back below: the
  /// reset itself emits NO diff.
  void _onExternalReset() {
    _reseeding = true;
    _controller.value = TextEditingValue(
      text: widget.producer.reseed(),
      selection: TextSelection.collapsed(offset: kImeSentinel.length),
    );
    _reseeding = false;
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
