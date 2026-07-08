/// Beacon decode contract — the Dart half of the beacon fixture pact.
///
/// Drives `Beacon.tryParse` against the EXACT shared fixtures in
/// `protocol/fixtures/beacon/` (per-language copies are forbidden, D-09),
/// mirroring the Rust encoder test in server-core. Constructed edge cases
/// cover what fixtures cannot express: oversized datagrams, non-UTF8 bytes,
/// non-object JSON, field-length and port-range boundaries.
///
/// The beacon is UNTRUSTED network input (BEACON.md): parsing must be total
/// — no exception may ever escape `tryParse`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/beacon.dart';

/// Fixture root relative to the package root — `flutter test` runs with
/// cwd = app/remote_control (fixture_test.dart idiom from remote_protocol).
const String fixtureRoot = '../../protocol/fixtures/beacon';

/// The datagram source address every test parse claims to come from.
/// `Beacon.host` must equal this — never a payload field.
final InternetAddress kSource = InternetAddress('192.168.1.7');

/// Guard: the relative fixture path only resolves from the package root.
/// Fail loudly with the canonical invocation if it breaks — a path typo
/// must never silently pass as "zero fixtures, zero failures".
void requireFixtureRoot() {
  if (!Directory(fixtureRoot).existsSync()) {
    fail(
      'Fixture root not found at $fixtureRoot '
      '(cwd: ${Directory.current.path}). '
      'The canonical invocation is: cd app/remote_control && flutter test',
    );
  }
}

/// Enumerate every `*.json` fixture, sorted by name; fail if empty.
List<File> fixtureFiles() {
  final files = Directory(fixtureRoot)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  expect(files, isNotEmpty, reason: 'no fixtures found in $fixtureRoot');
  return files;
}

String baseName(File file) =>
    file.path.split(Platform.pathSeparator).last.split('/').last;

/// A minimal valid beacon wire object (BEACON.md canonical shape) that
/// constructed edge cases mutate one field at a time.
Map<String, dynamic> validWire() => <String, dynamic>{
      'v': 1,
      'app': 'remote-control',
      'name': 'OMKAR-LAPTOP',
      'guid': '9f3c-test-guid',
      'port': 17777,
      'proto': '1.0',
    };

List<int> wireBytes(Object wire) => utf8.encode(jsonEncode(wire));

void main() {
  setUpAll(requireFixtureRoot);

  group('shared beacon fixtures', () {
    test('every fixture decodes or drops exactly as documented', () {
      requireFixtureRoot();
      for (final file in fixtureFiles()) {
        final name = baseName(file);
        final fixture =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final data = wireBytes(fixture['wire'] as Object);
        final expected = fixture['expect'] as Map<String, dynamic>;

        final beacon = Beacon.tryParse(data, kSource);

        if (expected['error'] == true) {
          expect(beacon, isNull,
              reason: '$name: datagram must be silently dropped');
          continue;
        }

        expect(beacon, isNotNull, reason: '$name: datagram must decode');
        expect(beacon!.name, expected['name'], reason: '$name: name mismatch');
        expect(beacon.guid, expected['guid'], reason: '$name: guid mismatch');
        expect(beacon.port, expected['port'], reason: '$name: port mismatch');
        expect(beacon.proto, expected['proto'],
            reason: '$name: proto mismatch');
        expect(beacon.host, kSource.address,
            reason: '$name: host must be the datagram SOURCE address — '
                'payload fields never override where it actually came from');
      }
    });
  });

  group('constructed edge cases', () {
    test('oversized datagram (>512 bytes) drops even if otherwise valid', () {
      // Padding rides an unknown key: without the size cap this datagram
      // WOULD decode (rule 6 ignores unknown fields), proving the length
      // check itself does the dropping — and does it BEFORE any parse.
      final wire = validWire()..['pad'] = 'x' * 520;
      final data = wireBytes(wire);
      expect(data.length, greaterThan(kMaxBeaconBytes),
          reason: 'test setup: payload must exceed the cap');
      expect(Beacon.tryParse(data, kSource), isNull);
    });

    test('non-UTF8 bytes drop', () {
      expect(Beacon.tryParse(<int>[0xff, 0xfe, 0xfd, 0x80], kSource), isNull);
    });

    test('valid JSON that is not an object drops', () {
      expect(Beacon.tryParse(utf8.encode('[1, 2, 3]'), kSource), isNull);
      expect(Beacon.tryParse(utf8.encode('"remote-control"'), kSource), isNull);
      expect(Beacon.tryParse(utf8.encode('42'), kSource), isNull);
    });

    test('name longer than 64 chars drops', () {
      final wire = validWire()..['name'] = 'x' * 65;
      expect(Beacon.tryParse(wireBytes(wire), kSource), isNull);
      // Boundary: exactly 64 is still valid.
      final atLimit = validWire()..['name'] = 'x' * 64;
      expect(Beacon.tryParse(wireBytes(atLimit), kSource), isNotNull);
    });

    test('port 0 and 65536 drop (valid range is 1..65535)', () {
      expect(
          Beacon.tryParse(wireBytes(validWire()..['port'] = 0), kSource),
          isNull);
      expect(
          Beacon.tryParse(wireBytes(validWire()..['port'] = 65536), kSource),
          isNull);
      // Boundaries: 1 and 65535 are valid.
      expect(
          Beacon.tryParse(wireBytes(validWire()..['port'] = 1), kSource),
          isNotNull);
      expect(
          Beacon.tryParse(wireBytes(validWire()..['port'] = 65535), kSource),
          isNotNull);
    });

    test('tryParse is total — never raises for any input', () {
      final garbage = <List<int>>[
        <int>[],
        utf8.encode('{'),
        utf8.encode('null'),
        utf8.encode('true'),
        utf8.encode('{"v":"1"}'),
        utf8.encode('{"v":1,"app":"remote-control"}'),
        List<int>.filled(600, 0),
        List<int>.filled(100, 0xff),
      ];
      for (final data in garbage) {
        expect(() => Beacon.tryParse(data, kSource), returnsNormally,
            reason: 'tryParse must silently return null, never crash '
                '(len=${data.length})');
        expect(Beacon.tryParse(data, kSource), isNull);
      }
    });

    test('constants match the server contract (BEACON.md)', () {
      expect(kBeaconPort, 17778,
          reason: 'must match DEFAULT_BEACON_PORT in server-core beacon.rs');
      expect(kMaxBeaconBytes, 512);
    });
  });
}
