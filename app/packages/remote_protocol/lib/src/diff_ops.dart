/// Diff-ops text helper (SPEC section 8, D-04).
///
/// The `text` payload is `{bs, ins}`: delete `bs` graphemes at the end of
/// the committed text, then insert `ins`. `bs` counts EXTENDED GRAPHEME
/// CLUSTERS (UAX #29) — never UTF-16 code units, never bytes.
library;

import 'package:characters/characters.dart';

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
/// `String.length` (UTF-16 units) is never used for count math. The UTF-16
/// offset of the common prefix's end is tracked only to slice [ins] out of
/// [newText] (offsets are per-grapheme, so the slice never splits a
/// cluster).
TextDiff computeDiff(String oldText, String newText) {
  final oldGraphemes = oldText.characters.toList();
  final newGraphemes = newText.characters.toList();

  // Common grapheme-cluster prefix walk.
  var prefix = 0;
  var insOffsetUtf16 = 0;
  while (prefix < oldGraphemes.length &&
      prefix < newGraphemes.length &&
      oldGraphemes[prefix] == newGraphemes[prefix]) {
    insOffsetUtf16 += newGraphemes[prefix].length;
    prefix++;
  }

  final bs = oldGraphemes.length - prefix;
  final ins = newText.substring(insOffsetUtf16);
  return TextDiff(bs, ins);
}
