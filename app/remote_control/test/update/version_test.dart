/// Version-compare contract — the Dart half of the D-26 cross-language pact.
///
/// Drives `SemVer` / `isNewer` against the EXACT shared truth table in
/// `protocol/fixtures/update/10-version-compare.json` (per-language copies are
/// forbidden, D-09), the same file the Rust comparator in `server-core` loads.
/// The cases are ITERATED from the fixture, never restated inline — a case the
/// fixture gains is a case this test gains, and a disagreement between the two
/// comparators is what this file exists to catch.
///
/// A version string is UNTRUSTED input (it arrives as a tag from the release
/// feed): parsing must be total — no exception may escape `SemVer.tryParse`,
/// and an unparseable version must never compare as newer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/update/version.dart';

/// The shared truth table, relative to the package root — `flutter test` runs
/// with cwd = app/remote_control (the beacon_test.dart idiom).
const String kVersionCompareFixture =
    '../../protocol/fixtures/update/10-version-compare.json';

/// Guard: the relative fixture path only resolves from the package root. Fail
/// loudly with the canonical invocation — a path typo must never silently pass
/// as "zero cases, zero failures".
void requireFixture() {
  if (!File(kVersionCompareFixture).existsSync()) {
    fail(
      'Fixture not found at $kVersionCompareFixture '
      '(cwd: ${Directory.current.path}). '
      'The canonical invocation is: cd app/remote_control && flutter test',
    );
  }
}

/// The `cases` array of the version-compare fixture.
List<Map<String, dynamic>> loadCases() {
  final root = jsonDecode(File(kVersionCompareFixture).readAsStringSync())
      as Map<String, dynamic>;
  final cases = (root['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
  expect(cases, isNotEmpty, reason: 'the truth table must not be empty');
  return cases;
}

void main() {
  group('version-compare shared truth table', () {
    test('the fixture is reachable and non-empty', () {
      requireFixture();
      expect(loadCases().length, greaterThanOrEqualTo(15));
    });

    test('every fixture case agrees with SemVer/isNewer', () {
      requireFixture();
      for (final c in loadCases()) {
        final a = c['a'] as String;
        final b = c['b'] as String;
        final expected = c['expect'] as String;
        final why = c['why'] as String? ?? '';
        final label = '"$a" vs "$b" => $expected ($why)';

        final parsedA = SemVer.tryParse(a);
        final parsedB = SemVer.tryParse(b);
        final aNewerThanB = isNewer(candidate: a, installed: b);
        final bNewerThanA = isNewer(candidate: b, installed: a);

        switch (expected) {
          case 'newer':
            expect(parsedA, isNotNull, reason: label);
            expect(parsedB, isNotNull, reason: label);
            expect(parsedA!.compareTo(parsedB!), greaterThan(0), reason: label);
            expect(aNewerThanB, isTrue, reason: label);
            expect(bNewerThanA, isFalse, reason: label);
          case 'older':
            expect(parsedA, isNotNull, reason: label);
            expect(parsedB, isNotNull, reason: label);
            expect(parsedA!.compareTo(parsedB!), lessThan(0), reason: label);
            expect(aNewerThanB, isFalse, reason: label);
            expect(bNewerThanA, isTrue, reason: label);
          case 'same':
            expect(parsedA, isNotNull, reason: label);
            expect(parsedB, isNotNull, reason: label);
            expect(parsedA!.compareTo(parsedB!), 0, reason: label);
            expect(aNewerThanB, isFalse, reason: label);
            expect(bNewerThanA, isFalse, reason: label);
          case 'unknown':
            // At least one side must have failed to parse...
            expect(
              parsedA == null || parsedB == null,
              isTrue,
              reason: '$label — expected at least one side to be unparseable',
            );
            // ...and an unknown must NEVER be newer, in either direction.
            expect(aNewerThanB, isFalse, reason: label);
            expect(bNewerThanA, isFalse, reason: label);
          default:
            fail('unhandled expect value "$expected" in $label');
        }
      }
    });

    test('the 1.10.0-vs-1.9.0 lexical trap is present in the fixture', () {
      requireFixture();
      final hasTrap = loadCases().any(
        (c) => c['a'] == '1.10.0' && c['b'] == '1.9.0' && c['expect'] == 'newer',
      );
      expect(hasTrap, isTrue,
          reason: 'the truth table must keep pinning the lexical trap');
    });
  });

  group('SemVer.tryParse', () {
    test('integer tuple compare, not lexical and not float', () {
      expect(
        SemVer.tryParse('1.10.0')!.compareTo(SemVer.tryParse('1.9.0')!),
        greaterThan(0),
      );
    });

    test('accepts a leading v and trims surrounding whitespace', () {
      expect(SemVer.tryParse('v1.4.0'), const SemVer(1, 4, 0));
      expect(SemVer.tryParse('  1.4.0  '), const SemVer(1, 4, 0));
    });

    test('rejects everything that is not an X.Y.Z triple', () {
      for (final bad in <String>[
        '1.4',
        '1.4.0.0',
        '1.4.0-rc1',
        '1.4.0+build7',
        '',
        '   ',
        'latest',
        'v',
        '-1.4.0',
        '1.4.x',
        'V1.4.0', // capital V is not the published tag form
      ]) {
        expect(SemVer.tryParse(bad), isNull, reason: 'must reject "$bad"');
      }
    });

    test('an out-of-range component is unknown, never saturated', () {
      // Matches the digit pattern but overflows a 64-bit int: tryParse must
      // return null rather than throw or clamp to a huge comparable value.
      expect(SemVer.tryParse('999999999999999999999.0.0'), isNull);
      expect(SemVer.tryParse('1.999999999999999999999.0'), isNull);
      expect(SemVer.tryParse('1.0.999999999999999999999'), isNull);
    });
  });

  group('isNewer', () {
    test('a pre-release is never offered', () {
      expect(isNewer(candidate: '1.4.0-rc1', installed: '1.4.0'), isFalse);
      expect(isNewer(candidate: '1.5.0-rc1', installed: '1.4.0'), isFalse);
    });

    test('a non-numeric tag is never offered', () {
      expect(isNewer(candidate: 'latest', installed: '1.4.0'), isFalse);
      expect(isNewer(candidate: '', installed: '1.4.0'), isFalse);
    });

    test('an overflowing component is never offered and throws nothing', () {
      expect(
        () =>
            isNewer(candidate: '999999999999999999999.0.0', installed: '1.4.0'),
        returnsNormally,
      );
      expect(
        isNewer(candidate: '999999999999999999999.0.0', installed: '1.4.0'),
        isFalse,
      );
    });

    test('equality is not an offer', () {
      expect(isNewer(candidate: '1.4.0', installed: '1.4.0'), isFalse);
      expect(isNewer(candidate: 'v1.4.0', installed: '1.4.0'), isFalse);
    });

    test('a genuine upgrade is an offer', () {
      expect(isNewer(candidate: '1.5.0', installed: '1.4.0'), isTrue);
      expect(isNewer(candidate: 'v1.10.0', installed: '1.9.0'), isTrue);
    });
  });

  group('normalize', () {
    test('strips a leading v and returns the canonical form', () {
      expect(normalize('v1.4.0'), '1.4.0');
      expect(normalize('1.4.0'), '1.4.0');
      expect(normalize(' v1.10.0 '), '1.10.0');
    });

    test('never zero-pads and never reformats', () {
      expect(normalize('1.4.0'), '1.4.0');
      expect(normalize('10.0.1'), '10.0.1');
    });

    test('returns null for anything unparseable', () {
      expect(normalize('1.4'), isNull);
      expect(normalize('1.4.0-rc1'), isNull);
      expect(normalize('latest'), isNull);
      expect(normalize(''), isNull);
      expect(normalize('999999999999999999999.0.0'), isNull);
    });
  });
}
