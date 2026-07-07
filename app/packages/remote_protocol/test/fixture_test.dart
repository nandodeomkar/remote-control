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
        final expectedOp = expected['op'] == 'move' ? opMove : opScroll;
        expect(frame.op, expectedOp, reason: '$name: op mismatch');
        expect(frame.dx, f32(expected['dx'] as num), reason: '$name: dx mismatch');
        expect(frame.dy, f32(expected['dy'] as num), reason: '$name: dy mismatch');

        final reencoded = frame.op == opMove
            ? encodeMove(frame.dx, frame.dy)
            : encodeScroll(frame.dx, frame.dy);
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
  /// Skips `05-auth-proof.json` by filename — special format, covered by
  /// auth_proof_test.dart. Text fixtures additionally exercise the
  /// `compute` block via [computeDiff] (Dart-only concern).
  void runJsonFamily(String family) {
    test('all scenarios', () {
      requireFixtureRoot();
      for (final file in fixtureFiles(family)) {
        final name = baseName(file);
        if (name == '05-auth-proof.json') continue;
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
}
