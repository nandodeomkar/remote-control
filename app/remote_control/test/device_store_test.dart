// Task 1 (TDD RED) — GUID-keyed multi-PC device store contract (D-07/D-10).
//
// Tokens live ONLY in secure storage under `token.<deviceKey>`; non-secret
// metadata lives in prefs as a JSON map under `devices` plus a
// `lastDeviceGuid` pointer (03-RESEARCH Pattern 7, exact schema).
//
// Seams are injected (latency_probe.dart house style): _FakeSecureKv is
// map-backed and throws PlatformException on demand — the Pitfall-5
// keystore-invalidation path (flutter_secure_storage issue #853) must
// degrade the device to unpaired and NEVER crash. No test touches real
// FlutterSecureStorage or SharedPreferences.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/store/device_store.dart';

/// A 64-hex token (sha256("") — distinctive, no accidental JSON collisions).
const _token =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Map-backed fake secure store; arms PlatformException on read/delete.
class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};

  /// When true, [read] throws PlatformException(code: 'keystore').
  bool throwOnRead = false;

  /// When true, [delete] throws AFTER recording the attempt.
  bool throwOnDelete = false;

  /// Every key a delete was attempted for (recorded even when armed to
  /// throw, so tests can assert the dead-entry cleanup was issued).
  final List<String> deletedKeys = [];

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) {
      throw PlatformException(code: 'keystore');
    }
    return backing[key];
  }

  @override
  Future<void> write(String key, String value) async {
    backing[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    if (throwOnDelete) {
      throw PlatformException(code: 'keystore');
    }
    backing.remove(key);
  }
}

/// Map-backed fake prefs store.
class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

const _meta = DeviceMeta(
  key: 'guid-1',
  name: 'DESKTOP-ABC',
  host: '192.168.1.7',
  port: 17777,
  lastConnectedAt: 1720400000,
);

void main() {
  late _FakeSecureKv secure;
  late _FakePrefsKv prefs;
  late DeviceStore store;

  setUp(() {
    secure = _FakeSecureKv();
    prefs = _FakePrefsKv();
    store = DeviceStore(secure: secure, prefs: prefs);
  });

  group('DeviceStore — token round-trip (secure storage only)', () {
    test('saveToken then tokenFor returns the token', () async {
      await store.saveToken('guid-1', _token);
      expect(await store.tokenFor('guid-1'), _token);
      expect(secure.backing['token.guid-1'], _token,
          reason: 'secure key schema is token.<deviceKey>');
    });

    test('deleteToken removes the token', () async {
      await store.saveToken('guid-1', _token);
      await store.deleteToken('guid-1');
      expect(await store.tokenFor('guid-1'), isNull);
      expect(secure.backing.containsKey('token.guid-1'), isFalse);
    });

    test('isPaired reflects token presence', () async {
      expect(await store.isPaired('guid-1'), isFalse);
      await store.saveToken('guid-1', _token);
      expect(await store.isPaired('guid-1'), isTrue);
      await store.deleteToken('guid-1');
      expect(await store.isPaired('guid-1'), isFalse);
    });
  });

  group('DeviceStore — keystore invalidation (Pitfall 5 / issue #853)', () {
    test('tokenFor returns null and deletes the dead entry on read throw',
        () async {
      secure.backing['token.guid-1'] = _token;
      secure.throwOnRead = true;

      expect(await store.tokenFor('guid-1'), isNull,
          reason: 'device degrades to unpaired — never a crash');
      expect(secure.deletedKeys, contains('token.guid-1'),
          reason: 'the dead entry is cleaned up');
    });

    test('a throw during the cleanup delete is also swallowed', () async {
      secure.throwOnRead = true;
      secure.throwOnDelete = true;

      // Completes with null; neither exception escapes.
      expect(await store.tokenFor('guid-1'), isNull);
    });

    test('isPaired is false under keystore failure', () async {
      secure.backing['token.guid-1'] = _token;
      secure.throwOnRead = true;
      expect(await store.isPaired('guid-1'), isFalse);
    });
  });

  group('DeviceStore — metadata round-trip (prefs "devices" JSON map)', () {
    test('upsertDevice + loadDevices preserve all fields', () async {
      await store.upsertDevice(_meta);

      final devices = await store.loadDevices();
      expect(devices, hasLength(1));
      final got = devices['guid-1']!;
      expect(got.key, 'guid-1');
      expect(got.name, 'DESKTOP-ABC');
      expect(got.host, '192.168.1.7');
      expect(got.port, 17777);
      expect(got.lastConnectedAt, 1720400000);

      // Pattern-7 schema assertion: entries live under the prefs 'devices'
      // key as a JSON object keyed by deviceKey.
      final raw =
          jsonDecode(prefs.backing['devices']!) as Map<String, Object?>;
      expect(raw.keys, contains('guid-1'));
    });

    test('upsertDevice replaces an existing entry', () async {
      await store.upsertDevice(_meta);
      await store.upsertDevice(const DeviceMeta(
        key: 'guid-1',
        name: 'DESKTOP-ABC',
        host: '192.168.1.42',
        port: 17778,
        lastConnectedAt: 1720500000,
      ));

      final devices = await store.loadDevices();
      expect(devices, hasLength(1));
      expect(devices['guid-1']!.host, '192.168.1.42');
      expect(devices['guid-1']!.port, 17778);
      expect(devices['guid-1']!.lastConnectedAt, 1720500000);
    });

    test('removeDevice deletes the entry', () async {
      await store.upsertDevice(_meta);
      await store.removeDevice('guid-1');
      expect(await store.loadDevices(), isEmpty);
    });

    test('loadDevices on a fresh store is an empty map', () async {
      expect(await store.loadDevices(), isEmpty);
    });

    test('a null lastConnectedAt survives the round-trip', () async {
      await store.upsertDevice(const DeviceMeta(
        key: 'guid-2',
        name: 'LAPTOP-XYZ',
        host: '10.0.0.5',
        port: 17777,
      ));
      final devices = await store.loadDevices();
      expect(devices['guid-2']!.lastConnectedAt, isNull);
    });

    test('WR-02: a corrupt row is skipped, good rows still load', () async {
      // One valid entry plus a schema-drifted one (missing required fields).
      prefs.backing['devices'] = jsonEncode({
        'guid-good': {
          'name': 'DESKTOP-ABC',
          'host': '192.168.1.7',
          'port': 17777,
        },
        'guid-bad': {'name': 'BROKEN'}, // no host/port -> fromJson would throw
      });

      final devices = await store.loadDevices();
      expect(devices.keys, contains('guid-good'));
      expect(devices.keys, isNot(contains('guid-bad')),
          reason: 'a corrupt row is skipped, not fatal');
      expect(devices['guid-good']!.host, '192.168.1.7');
    });

    test('WR-02: a corrupt top-level blob degrades to empty, never throws',
        () async {
      prefs.backing['devices'] = '{not valid json';
      expect(await store.loadDevices(), isEmpty);
    });
  });

  group('DeviceStore — last-device pointer (prefs "lastDeviceGuid")', () {
    test('setLastDevice / lastDeviceKey round-trip', () async {
      expect(await store.lastDeviceKey(), isNull);
      await store.setLastDevice('guid-1');
      expect(await store.lastDeviceKey(), 'guid-1');
      expect(prefs.backing['lastDeviceGuid'], 'guid-1',
          reason: 'pointer lives under the exact prefs key lastDeviceGuid');
    });
  });

  group('manualDeviceKey + adoptGuid — manual-connection identity (D-03)', () {
    test('manualDeviceKey formats manual:<host>:<port>', () {
      expect(manualDeviceKey('192.168.1.7', 17777), 'manual:192.168.1.7:17777');
    });

    test('adoptGuid moves token + metadata to the GUID key', () async {
      final manualKey = manualDeviceKey('192.168.1.7', 17777);
      await store.saveToken(manualKey, _token);
      await store.upsertDevice(DeviceMeta(
        key: manualKey,
        name: 'DESKTOP-ABC',
        host: '192.168.1.7',
        port: 17777,
        lastConnectedAt: 1720400000,
      ));

      await store.adoptGuid(manualKey: manualKey, guid: 'guid-9');

      // Token migrated to token.guid-9; manual token gone.
      expect(await store.tokenFor('guid-9'), _token);
      expect(await store.tokenFor(manualKey), isNull);
      expect(secure.backing.containsKey('token.$manualKey'), isFalse);

      // Metadata re-keyed to guid-9, fields preserved, manual entry removed.
      final devices = await store.loadDevices();
      expect(devices.containsKey(manualKey), isFalse);
      final adopted = devices['guid-9']!;
      expect(adopted.key, 'guid-9');
      expect(adopted.name, 'DESKTOP-ABC');
      expect(adopted.host, '192.168.1.7');
      expect(adopted.port, 17777);
      expect(adopted.lastConnectedAt, 1720400000);
    });

    test('adoptGuid updates lastDeviceGuid when it pointed at the manual key',
        () async {
      final manualKey = manualDeviceKey('192.168.1.7', 17777);
      await store.saveToken(manualKey, _token);
      await store.upsertDevice(DeviceMeta(
        key: manualKey,
        name: 'DESKTOP-ABC',
        host: '192.168.1.7',
        port: 17777,
      ));
      await store.setLastDevice(manualKey);

      await store.adoptGuid(manualKey: manualKey, guid: 'guid-9');

      expect(await store.lastDeviceKey(), 'guid-9');
    });

    test('adoptGuid leaves lastDeviceGuid alone when it points elsewhere',
        () async {
      final manualKey = manualDeviceKey('192.168.1.7', 17777);
      await store.saveToken(manualKey, _token);
      await store.upsertDevice(DeviceMeta(
        key: manualKey,
        name: 'DESKTOP-ABC',
        host: '192.168.1.7',
        port: 17777,
      ));
      await store.setLastDevice('guid-other');

      await store.adoptGuid(manualKey: manualKey, guid: 'guid-9');

      expect(await store.lastDeviceKey(), 'guid-other');
    });
  });

  group('Secrets discipline — the token never enters prefs', () {
    test('after saveToken + upsertDevice, prefs JSON has no token substring',
        () async {
      await store.saveToken('guid-1', _token);
      await store.upsertDevice(_meta);
      await store.setLastDevice('guid-1');

      final prefsJson = jsonEncode(prefs.backing);
      expect(prefsJson.contains(_token), isFalse);
      // No 16-char slice of the token appears either (source-of-truth
      // assertion that no partial token leaks into the prefs schema).
      for (var i = 0; i + 16 <= _token.length; i += 8) {
        expect(prefsJson.contains(_token.substring(i, i + 16)), isFalse,
            reason: 'token slice at offset $i must not appear in prefs');
      }
    });
  });
}
