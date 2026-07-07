/// Diff-ops text helper (SPEC section 8, D-04).
///
/// The `text` payload is `{bs, ins}`: delete `bs` graphemes at the end of
/// the committed text, then insert `ins`. `bs` counts EXTENDED GRAPHEME
/// CLUSTERS (UAX #29) — never UTF-16 code units, never bytes.
library;

/// A computed text diff: delete [bs] trailing graphemes, insert [ins].
class TextDiff {
  /// Number of extended grapheme clusters to delete at the end.
  final int bs;

  /// Text to insert after deletion.
  final String ins;

  /// Creates a text diff.
  const TextDiff(this.bs, this.ins);
}

/// Compute the diff from [oldText] to [newText]:
///
/// - `bs = graphemes(oldText) - graphemes(commonPrefix(oldText, newText))`
/// - `ins = suffix of newText after the common prefix`
///
/// Counting uses extended grapheme clusters via `package:characters` —
/// `String.length` (UTF-16 units) is forbidden for count math.
TextDiff computeDiff(String oldText, String newText) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}
