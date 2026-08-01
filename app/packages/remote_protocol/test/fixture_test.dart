/// Golden-fixture harness — the Dart half of phase success criterion 1.
///
/// Loads the EXACT files in `protocol/fixtures/` (per-language copies are
/// forbidden, D-09) and drives the codec contracts against them, mirroring
/// the Rust harness (`server/server-core/tests/fixtures.rs`). Fixture
/// directories are enumerated at runtime: adding a fixture file
/// automatically extends coverage.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

/// Fixture root relative to the package root — `dart test` runs with
/// cwd = package root (RESEARCH Pattern 1 / assumption A1).
const String fixtureRoot = '../../../protocol/fixtures';

/// Guard (Pitfall 8): the relative fixture path only resolves from the
/// package root. Fail loudly with the canonical invocation if it breaks.
void requireFixtureRoot() {
  if (!Directory(fixtureRoot).existsSync()) {
    fail(
      'Fixture root not found at $fixtureRoot (cwd: ${Directory.current.path}). '
      'The canonical invocation is: cd app/packages/remote_protocol && dart test',
    );
  }
}

/// Enumerate every `*.json` fixture in a family directory, sorted by name.
List<File> fixtureFiles(String family) {
  final dir = Directory('$fixtureRoot/$family');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  expect(files, isNotEmpty, reason: 'no fixtures found in ${dir.path}');
  return files;
}

/// Load one fixture file as a JSON map.
Map<String, dynamic> loadFixture(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

/// Basename of a fixture file, for assertion messages and skip logic.
String baseName(File file) => file.path.split(Platform.pathSeparator).last.split('/').last;

/// Fixture files that are NOT wire fixtures — they carry no `wire`/`expect`
/// envelope and are covered by bespoke loaders elsewhere, so the shared
/// [runJsonFamily] harness must skip them by name.
///
/// The alternative — a per-call skip argument — would have moved the
/// exclusion to the registration site, where a family with an unusual file
/// is easy to register without it. Keeping the list here means the harness
/// itself knows which files it cannot read, and the registration lines all
/// stay `runJsonFamily('family')`.
const Map<String, Set<String>> specialCaseFixtures = {
  // Special format; covered by auth_proof_test.dart (fixtures README
  // special case 1).
  'handshake': {'05-auth-proof.json'},
  // protocol 1.8: `update/` is a MIXED-KIND directory (12-02). 01-09 are
  // standard wire fixtures; 10-12 are the cross-language version-compare
  // truth table and two captured releases/latest feed shapes, which have no
  // `t`/`p` envelope at all and belong to 12-07's comparator and feed-parser
  // suites (fixtures README special cases 3, 4 and 5).
  'update': {
    '10-version-compare.json',
    '11-releases-latest.json',
    '12-releases-latest-null-digest.json',
  },
};

/// The wire fixtures of a family: every `*.json` minus the special cases.
List<File> wireFixtureFiles(String family) {
  final special = specialCaseFixtures[family] ?? const <String>{};
  return fixtureFiles(family)
      .where((f) => !special.contains(baseName(f)))
      .toList();
}

/// Convert a JSON number to its f32-rounded double so Dart doubles compare
/// exactly against decoded f32 values (fixtures are f32-exact by
/// construction — no epsilon comparison anywhere).
double f32(num v) => (Float32List(1)..[0] = v.toDouble())[0];

void main() {
  setUpAll(requireFixtureRoot);

  group('mouse-binary fixtures', () {
    test('all scenarios', () {
      requireFixtureRoot();
      for (final file in fixtureFiles('mouse-binary')) {
        final name = baseName(file);
        final fixture = loadFixture(file);

        final wireHex = fixture['wire'] as String;
        final bytes = Uint8List.fromList(hexDecode(wireHex));
        final expected = fixture['expect'] as Map<String, dynamic>;

        if (expected['error'] == true) {
          expect(
            () => decodeMouseFrame(bytes),
            throwsFormatException,
            reason: '$name: decode must fail (SPEC section 9 strict decode)',
          );
          continue;
        }

        final frame = decodeMouseFrame(bytes);
        // Three-way, NO silent fallback: the old two-way ternary decoded any
        // non-'move' fixture as a scroll, so a zoom fixture would have passed
        // while proving nothing (quick 260731-euq).
        final opName = expected['op'] as String;
        final expectedOp = switch (opName) {
          'move' => opMove,
          'scroll' => opScroll,
          'zoom' => opZoom,
          _ => fail('$name: unknown fixture op "$opName"'),
        };
        expect(frame.op, expectedOp, reason: '$name: op mismatch');
        expect(frame.dx, f32(expected['dx'] as num), reason: '$name: dx mismatch');
        expect(frame.dy, f32(expected['dy'] as num), reason: '$name: dy mismatch');

        final reencoded = switch (frame.op) {
          opMove => encodeMove(frame.dx, frame.dy),
          opScroll => encodeScroll(frame.dx, frame.dy),
          opZoom => encodeZoom(frame.dx, frame.dy),
          _ => fail('$name: unknown decoded op 0x${frame.op.toRadixString(16)}'),
        };
        expect(
          hexEncode(reencoded),
          wireHex,
          reason: '$name: encode(decode(wire)) must reproduce the original 9 bytes',
        );
      }
    });
  });

  /// Shared driver for the JSON text-frame families (`handshake/`, `text/`).
  ///
  /// Skips the [specialCaseFixtures] of the family by filename — files with
  /// no `wire`/`expect` envelope, covered by their own suites. Text fixtures
  /// additionally exercise the `compute` block via [computeDiff] (Dart-only
  /// concern).
  void runJsonFamily(String family) {
    test('all scenarios', () {
      requireFixtureRoot();
      for (final file in wireFixtureFiles(family)) {
        final name = baseName(file);
        final fixture = loadFixture(file);

        final wire = jsonEncode(fixture['wire']);
        final expected = fixture['expect'] as Map<String, dynamic>;

        // Version rejection is the SERVER's job, not the codec's (D-06):
        // a major-version-2 hello must DECODE fine; the Rust integration
        // suite covers the server-side err{versionMismatch} + close.
        if (expected['reason'] == 'versionMismatch') {
          final decoded = decodeText(wire);
          expect(
            decoded.msg,
            isA<RemoteMessage>(),
            reason: '$name: codec must decode a version-mismatched hello',
          );
          continue;
        }

        if (expected['error'] == true) {
          expect(
            () => decodeText(wire),
            throwsFormatException,
            reason: '$name: decode must fail (missing required field, D-05)',
          );
          continue;
        }

        final decoded = decodeText(wire);
        final reencoded =
            jsonDecode(encodeMessage(decoded.msg, seq: decoded.seq));
        // Order-insensitive canonical comparison — this is what proves
        // D-05 unknown-field dropping on 01-hello-ok.
        expect(
          const DeepCollectionEquality().equals(reencoded, expected),
          isTrue,
          reason: '$name: encode(decode(wire)) must equal the canonical '
              'expect envelope\n  got:      $reencoded\n  expected: $expected',
        );

        // Dart-only: the compute block must reproduce the wire's diff-ops
        // via grapheme-correct computeDiff (fixtures README special case 2).
        final compute = fixture['compute'] as Map<String, dynamic>?;
        if (compute != null) {
          final diff = computeDiff(
            compute['old'] as String,
            compute['new'] as String,
          );
          final p = expected['p'] as Map<String, dynamic>;
          expect(diff.bs, p['bs'], reason: '$name: computeDiff bs mismatch');
          expect(diff.ins, p['ins'], reason: '$name: computeDiff ins mismatch');
        }
      }
    });
  }

  group('handshake fixtures', () {
    runJsonFamily('handshake');
  });

  group('text fixtures', () {
    runJsonFamily('text');
  });

  group('volume fixtures', () {
    runJsonFamily('volume');
  });

  // protocol 1.2 (06-01/06-03): WindowInfo gains optional icon (base64 PNG) +
  // path (resolved exe). 01-with-icon-path decodes both fields and drops the
  // unknown `future` field on re-encode (D-05); 02-legacy decodes icon==null /
  // path==null and re-encodes WITHOUT the optional keys (skip_serializing_if
  // mirror). Both round-trip through the shared harness.
  group('window_info fixtures', () {
    runJsonFamily('window_info');
  });

  // protocol 1.3 (07-02, SRV-05/D-07): additive S→C input.blocked push.
  // 01-input-blocked decodes reason=="elevated" and drops the unknown
  // `future` field on re-encode (D-05), proving the shared golden fixture
  // decodes identically in the Rust and Dart codecs.
  group('input_blocked fixtures', () {
    runJsonFamily('input_blocked');
  });

  // protocol 1.4 (BROW-01): the additive tabs.* family. 01 round-trips a
  // tabs.changed with an icon-carrying TabEl (unknown `future` field dropped
  // per D-05) and an iconless one (icon key omitted on re-encode); 02 is the
  // never-connected tabs.list reply; 03/05 round-trip tabs.activate/close;
  // 04 proves a missing required `id` is a hard decode error — the same
  // shared golden fixtures the Rust harness exercises. 09-tabs-changed-
  // bookmarked (protocol 1.6) additionally proves the TRI-STATE `bookmarked`
  // flag round-trips in all three states — true, false, and absent staying
  // absent (null = UNKNOWN, D-11). It needs no new registration because this
  // family already enumerates every file in its directory.
  group('tabs fixtures', () {
    runJsonFamily('tabs');
  });

  // protocol 1.6 (phase 11): the additive bm.* family. 01 round-trips a
  // bm.changed carrying a folder node with `count` and `truncated`, a locked
  // root, and a plain link that re-encodes with NO optional keys — dropping
  // the unknown `future` field per the SPEC section 1 rule; 02 is the
  // never-connected bm.list reply and 09 the bare request; 03-06 round-trip
  // the four commands with `nodeId` as a String and `tabId` as an int; 07
  // and 08 prove a missing required field is a hard decode error. Hard-
  // registered because neither harness globs directories (the 07-02
  // input.blocked lesson): an unregistered family yields zero coverage AND
  // zero failures, silently.
  group('bookmarks fixtures', () {
    runJsonFamily('bookmarks');
  });

  // protocol 1.8 (phase 12): the additive update.* family. 01 is the
  // empty-payload update.check request whose canonical re-encode must still
  // emit `p` as `{}`; 02 round-trips a full update.status including the
  // nested lastUpdate object and drops the unknown `future` key inside it
  // (D-05); 03 is the minimal status where BOTH optionals stay absent rather
  // than becoming null; 04 is the one-key update.apply that carries the D-14
  // no-locator-authority rule structurally; 05-07 cover the three
  // update.progress shapes (pct belongs to `downloading` alone, `failed`
  // always carries `error`, `uptodate` carries nothing else); 08 and 09
  // prove a missing required field is a hard decode error. Hard-registered
  // because neither harness globs directories (the 07-02 input.blocked
  // lesson): an unregistered family yields zero coverage AND zero failures,
  // silently. The directory is MIXED-KIND — 10-12 are excluded by
  // specialCaseFixtures above and belong to 12-07.
  group('update fixtures', () {
    runJsonFamily('update');

    // Guards the exclusion above from the failure mode it creates: if a
    // future special-case entry (or a typo in one) silently removed a wire
    // fixture from the harness, `all scenarios` would still pass while
    // covering less. Nine is the count 12-02 froze.
    test('exercises exactly nine wire fixtures', () {
      requireFixtureRoot();
      expect(
        wireFixtureFiles('update').map(baseName).toList(),
        hasLength(9),
        reason: 'the update family has nine wire fixtures (01-09); '
            '10-12 are special cases with bespoke loaders',
      );
    });
  });
}
