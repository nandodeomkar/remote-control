/// ImeDiffProducer behavior tests (04-05 Task 1, KEY-01, D-08).
///
/// The producer turns committed-text transitions from the hidden IME field
/// into grapheme-exact `text {bs, ins}` messages via the fixture-proven
/// `computeDiff` (SPEC section 8). The transitions below mirror the shared
/// protocol fixtures: 01-simple-insert, 02-ime-revision, 03-emoji,
/// 04-rapid-backspace.
///
/// SPEC section 12 redaction: assertions compare values; nothing here prints
/// or logs typed content (threat T-04-03).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/keyboard/diff_ops.dart';

void main() {
  late List<TextMsg> emitted;
  late ImeDiffProducer producer;

  setUp(() {
    emitted = <TextMsg>[];
    producer = ImeDiffProducer(emit: emitted.add);
  });

  test('sentinel is 8 zero-width spaces, each its own grapheme', () {
    expect(kImeSentinel.runes.length, 8);
    expect(kImeSentinel.runes.every((r) => r == 0x200B), isTrue);
    expect(producer.seedText, kImeSentinel);
  });

  test('plain insert emits exactly one TextMsg(bs: 0, ins: "a")', () {
    producer.onChanged('${kImeSentinel}a');

    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 0);
    expect(emitted.single.ins, 'a');
  });

  test('IME revision (fixture 02): thw -> "the " emits bs:1 ins:"e "', () {
    // Seed the committed text to sentinel+'thw' (the pre-revision state).
    producer.onChanged('${kImeSentinel}thw');
    emitted.clear();

    // Autocomplete revises the committed tail: 'thw' -> 'the '.
    // Common grapheme prefix is 'th' -> bs = 3 - 2 = 1, ins = 'e '
    // (02-ime-revision fixture compute block, via computeDiff).
    producer.onChanged('${kImeSentinel}the ');

    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 1);
    expect(emitted.single.ins, 'e ');
  });

  test('emoji (fixture 03): one grapheme in, one bs out', () {
    // U+1F44B U+1F3FD (waving hand + medium skin tone) is ONE extended
    // grapheme cluster — 2 runes, 4 UTF-16 units, but exactly one grapheme.
    const wave = '\u{1F44B}\u{1F3FD}';

    producer.onChanged('$kImeSentinel$wave');
    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 0);
    expect(emitted.single.ins, wave);

    emitted.clear();
    producer.onChanged(kImeSentinel);
    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 1);
    expect(emitted.single.ins, isEmpty);
  });

  test('boundary backspace shrinks the sentinel and triggers reseed', () {
    // Committed == full sentinel; the user backspaces at the boundary.
    final shrunk = kImeSentinel.substring(0, kImeSentinel.length - 1);
    producer.onChanged(shrunk);

    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 1);
    expect(emitted.single.ins, isEmpty);
    expect(producer.needsReseed(shrunk), isTrue);

    // Reseed restores the sentinel WITHOUT emitting anything.
    emitted.clear();
    final seed = producer.reseed();
    expect(seed, kImeSentinel);
    expect(emitted, isEmpty);

    // Committed is back at the sentinel: an insert now diffs cleanly.
    producer.onChanged('${kImeSentinel}x');
    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 0);
    expect(emitted.single.ins, 'x');
  });

  test('needsReseed is false while the full sentinel prefix is intact', () {
    expect(producer.needsReseed(kImeSentinel), isFalse);
    expect(producer.needsReseed('${kImeSentinel}typed text'), isFalse);
  });

  test('no-op change emits nothing', () {
    producer.onChanged('${kImeSentinel}abc');
    emitted.clear();

    producer.onChanged('${kImeSentinel}abc');
    expect(emitted, isEmpty);
  });

  test('rapid backspace (fixture 04): three shrinks, three bs:1 messages',
      () {
    producer.onChanged('${kImeSentinel}abc');
    emitted.clear();

    producer.onChanged('${kImeSentinel}ab');
    producer.onChanged('${kImeSentinel}a');
    producer.onChanged(kImeSentinel);

    expect(emitted, hasLength(3));
    for (final msg in emitted) {
      expect(msg.bs, 1);
      expect(msg.ins, isEmpty);
    }
  });

  test('reset restores the sentinel-committed state', () {
    producer.onChanged('${kImeSentinel}hello');
    emitted.clear();

    producer.reset();
    expect(emitted, isEmpty);

    // After reset the committed text is the sentinel again.
    producer.onChanged('${kImeSentinel}h');
    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 0);
    expect(emitted.single.ins, 'h');
  });
}
