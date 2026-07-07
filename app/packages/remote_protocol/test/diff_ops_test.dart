/// Direct unit cases for grapheme-correct diff-ops (SPEC section 8, D-04).
///
/// `bs` counts EXTENDED GRAPHEME CLUSTERS — the emoji cases fail any
/// implementation counting UTF-16 code units (`String.length`) or bytes.
library;

import 'package:remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('plain insert from empty: bs 0, ins hello', () {
    final diff = computeDiff('', 'hello');
    expect(diff.bs, 0);
    expect(diff.ins, 'hello');
  });

  test('IME revision thw -> "the ": bs 1, ins "e "', () {
    final diff = computeDiff('thw', 'the ');
    expect(diff.bs, 1);
    expect(diff.ins, 'e ');
  });

  test('emoji backspace hi\u{1F44D} -> hi: bs 1 (grapheme, not UTF-16)', () {
    // '👍' is one grapheme but TWO UTF-16 code units — String.length-based
    // counting would say bs 2 and corrupt adjacent text on the PC.
    final diff = computeDiff('hi👍', 'hi');
    expect(diff.bs, 1);
    expect(diff.ins, '');
  });

  test('rapid backspace over modifier emoji: hello\u{1F44B}\u{1F3FD}! -> hel: bs 4', () {
    // 'hello👋🏽!' = h,e,l,l,o,👋🏽,! = 7 graphemes (waving hand + skin-tone
    // modifier is ONE extended grapheme cluster); common prefix 'hel' = 3,
    // so bs = 7 - 3 = 4.
    final diff = computeDiff('hello👋🏽!', 'hel');
    expect(diff.bs, 4);
    expect(diff.ins, '');
  });
}
