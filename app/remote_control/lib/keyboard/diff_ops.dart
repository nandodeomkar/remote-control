/// ImeDiffProducer — committed-text diffing for the hidden IME field
/// (04-05, KEY-01, D-08).
///
/// Turns `TextEditingController.onChanged` transitions into grapheme-exact
/// `text {bs, ins}` messages via the fixture-proven `computeDiff` from
/// `remote_protocol` (SPEC section 8) — the ONLY diff engine; never
/// re-implemented here.
///
/// SENTINEL MODEL: an empty TextField swallows backspace — the IME sends no
/// delete and `onChanged` never fires, so the PC would stop receiving `bs`
/// frames the moment the user backspaces past everything typed this session.
/// The controller text therefore always starts with [kImeSentinel] — eight
/// zero-width spaces (U+200B), each its own extended grapheme cluster,
/// visually absent — so the field is never empty and a backspace at the
/// boundary still shrinks the text. Deletions of sentinel graphemes ARE
/// forwarded as `bs` to the PC; the owning widget then re-seeds the field
/// (via [needsReseed] / [reseed]) without emitting.
///
/// Pure Dart: imports `remote_protocol` only — no Flutter. SPEC section 12
/// redaction is mandatory: this class never logs or prints `ins`/committed
/// content (threat T-04-03).
library;

import 'package:remote_protocol/remote_protocol.dart';

/// The invisible field seed: 8 x U+200B zero-width space. Each ZWSP is its
/// own grapheme cluster, so boundary backspaces shrink it one `bs` at a time.
/// Spelled as escapes — a literal ZWSP run would be invisible in source.
const String kImeSentinel =
    '\u200B\u200B\u200B\u200B\u200B\u200B\u200B\u200B';

/// Committed-text diff producer for the hidden IME field.
class ImeDiffProducer {
  /// Emits each non-empty diff as a [TextMsg] (wired to the reliable path).
  final void Function(TextMsg) emit;

  /// Previous committed text (starts at the sentinel).
  String _committed = kImeSentinel;

  /// Creates a producer with a constructor-injected emitter.
  ImeDiffProducer({required this.emit});

  /// Initial controller value: the sentinel prefix.
  String get seedText => kImeSentinel;

  /// Handles a committed-text transition from the field. Computes the
  /// grapheme-exact diff against the previous committed text, emits a
  /// [TextMsg] when non-empty, then stores [next] as committed.
  void onChanged(String next) {
    final diff = computeDiff(_committed, next);
    if (diff.bs != 0 || diff.ins.isNotEmpty) {
      emit(TextMsg(bs: diff.bs, ins: diff.ins));
    }
    _committed = next;
  }

  /// True when [current] no longer starts with the full sentinel — the user
  /// has backspaced into it and the field must be re-seeded.
  bool needsReseed(String current) => !current.startsWith(kImeSentinel);

  /// Returns a fresh seed and resets the committed text to it. Emits
  /// NOTHING — the owning widget writes the seed back to the controller as a
  /// programmatic (non-user) change.
  String reseed() {
    _committed = kImeSentinel;
    return kImeSentinel;
  }

  /// Restores the sentinel-committed state (panel close / disconnect
  /// hygiene). Emits nothing.
  void reset() {
    _committed = kImeSentinel;
  }
}
