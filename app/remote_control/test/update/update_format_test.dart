/// The two copy formatters, asserted at every boundary the UI-SPEC names.
///
/// These are binding contract values, not examples: the `{ago}` table and the
/// `{size}` rule are quoted by both the phone and the PC settings window, so a
/// drift here would make the two surfaces describe one state with two
/// different sentences.
///
/// The singular/plural boundaries get their own cases because "1 minutes ago"
/// is the classic way a hand-rolled formatter ships broken, and the real asset
/// byte counts get theirs because the whole point of D-08 is that the user
/// sees a truthful size before agreeing to a ~70 MB download.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/update/update_format.dart';

void main() {
  group('formatAgo — the UI-SPEC {ago} table', () {
    test('under 60 seconds is "just now", with no count', () {
      expect(formatAgo(Duration.zero), 'just now');
      expect(formatAgo(const Duration(seconds: 1)), 'just now');
      expect(formatAgo(const Duration(seconds: 59)), 'just now');
    });

    test('exactly 1 minute is singular', () {
      expect(formatAgo(const Duration(minutes: 1)), '1 minute ago');
      expect(formatAgo(const Duration(seconds: 60)), '1 minute ago');
      // Still one minute until the second minute completes.
      expect(formatAgo(const Duration(seconds: 119)), '1 minute ago');
    });

    test('2 or more minutes is plural', () {
      expect(formatAgo(const Duration(minutes: 2)), '2 minutes ago');
      expect(formatAgo(const Duration(minutes: 59)), '59 minutes ago');
    });

    test('exactly 1 hour is singular and switches unit at 60 minutes', () {
      expect(formatAgo(const Duration(minutes: 60)), '1 hour ago');
      expect(formatAgo(const Duration(hours: 1)), '1 hour ago');
    });

    test('2 or more hours is plural, up to the 23-hour edge', () {
      expect(formatAgo(const Duration(hours: 2)), '2 hours ago');
      expect(formatAgo(const Duration(hours: 23)), '23 hours ago');
      expect(
        formatAgo(const Duration(hours: 23, minutes: 59)),
        '23 hours ago',
      );
    });

    test('exactly 1 day is singular and switches unit at 24 hours', () {
      expect(formatAgo(const Duration(hours: 24)), '1 day ago');
      expect(formatAgo(const Duration(days: 1)), '1 day ago');
      expect(formatAgo(const Duration(hours: 47)), '1 day ago');
    });

    test('2 or more days is plural', () {
      expect(formatAgo(const Duration(days: 2)), '2 days ago');
      expect(formatAgo(const Duration(days: 30)), '30 days ago');
      expect(formatAgo(const Duration(days: 365)), '365 days ago');
    });

    test('a future-dated elapsed renders as "just now", never a negative', () {
      expect(formatAgo(const Duration(hours: -3)), 'just now');
      expect(formatAgo(const Duration(days: -30)), 'just now');
    });
  });

  group('formatSize — the UI-SPEC {size} rule', () {
    test('the real APK renders as a rounded integer', () {
      // 69 630 935 B / 1 048 576 = 66.41 MB -> at or above the cutoff.
      expect(formatSize(69630935), '66 MB');
    });

    test('the real setup exe renders with one decimal', () {
      // 5 177 240 B / 1 048 576 = 4.94 MB -> below the cutoff.
      expect(formatSize(5177240), '4.9 MB');
    });

    test('the real extension zip is sub-megabyte and still renders a size',
        () {
      // 13 454 B — the extension row never shows a size in the UI (it reads
      // "updates with your PC"), but the formatter must stay total.
      expect(formatSize(13454), '0.0 MB');
    });

    test('zero renders as a size, not as an empty string', () {
      expect(formatSize(0), '0.0 MB');
    });

    test('the 10 MB decimal-to-integer switch', () {
      expect(formatSize(9961472), '9.5 MB'); // 9.5 MB — below the cutoff
      expect(formatSize(10485760), '10 MB'); // exactly 10.0 MB — at the cutoff
      expect(formatSize(11534336), '11 MB'); // 11.0 MB — above the cutoff
    });

    test('a negative byte count is clamped rather than rendered', () {
      expect(formatSize(-1), '0.0 MB');
      expect(formatSize(-69630935), '0.0 MB');
    });

    test('the suffix is a space then MB, on every branch', () {
      for (final bytes in <int>[0, 13454, 5177240, 10485760, 69630935]) {
        expect(formatSize(bytes), endsWith(' MB'), reason: '$bytes');
      }
    });
  });

  group('typography guard', () {
    test('no formatter emits three periods or an ASCII arrow', () {
      final outputs = <String>[
        formatAgo(Duration.zero),
        formatAgo(const Duration(minutes: 1)),
        formatAgo(const Duration(hours: 1)),
        formatAgo(const Duration(days: 1)),
        formatSize(0),
        formatSize(69630935),
      ];
      for (final out in outputs) {
        expect(out.contains('...'), isFalse, reason: out);
        expect(out.contains('->'), isFalse, reason: out);
      }
    });
  });
}
