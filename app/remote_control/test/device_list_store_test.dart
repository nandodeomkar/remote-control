// Task 1 (TDD) — DeviceListModel: the pure merge/evict/adopt logic behind
// the device list (D-02, CONN-01).
//
// Six behavior groups from 03-06-PLAN:
//   1. GUID merge (one entry per guid; duplicate names stay distinct rows)
//   2. Eviction (live -> grayed after >kBeaconEvictMillis; discovery-only
//      unpaired entries disappear instead)
//   3. No per-packet churn (identical beacon -> equal entries list)
//   4. mergeStored (remembered-offline devices grayed at last-known address)
//   5. Ordering (live sorted by name, then grayed remembered)
//   6. Adoption (manual:<host>:<port> -> real GUID, exactly once)
//
// Fake clock throughout (latency_probe_test style): nowMillis is always an
// explicit argument — the model owns no Timer.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/beacon.dart';
import 'package:remote_control/store/device_list_store.dart';
import 'package:remote_control/store/device_store.dart';

/// Builds a validated beacon the way the listener would: host is ALWAYS the
/// datagram source address (T-03-13), so tests set it via [source].
Beacon beaconFrom({
  required String guid,
  String name = 'OMKAR-LAPTOP',
  String source = '192.168.1.7',
  int port = 17777,
}) =>
    Beacon(
      guid: guid,
      name: name,
      port: port,
      proto: '1.0',
      source: InternetAddress(source),
    );

DeviceMeta meta({
  required String key,
  String name = 'OLD-PC',
  String host = '192.168.1.50',
  int port = 17777,
}) =>
    DeviceMeta(key: key, name: name, host: host, port: port);

void main() {
  group('DeviceListModel — GUID merge (CONN-01)', () {
    test('two beacons with the same guid update ONE entry, new host wins',
        () {
      final model = DeviceListModel();
      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.7'), 0);
      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.99'), 2000);

      final entries = model.entries;
      expect(entries, hasLength(1),
          reason: 'same guid must merge into one row (PC IP change)');
      expect(entries.single.key, 'g1');
      expect(entries.single.host, '192.168.1.99',
          reason: 'the newer beacon host replaces the old one');
      expect(entries.single.live, isTrue);
    });

    test('two guids with the SAME name yield two distinct rows', () {
      final model = DeviceListModel();
      model.onBeacon(
          beaconFrom(guid: 'g1', name: 'LAPTOP', source: '192.168.1.7'), 0);
      model.onBeacon(
          beaconFrom(guid: 'g2', name: 'LAPTOP', source: '192.168.1.8'), 0);

      final entries = model.entries;
      expect(entries, hasLength(2),
          reason: 'GUID disambiguation: duplicate names stay distinct');
      expect(entries.map((e) => e.key).toSet(), {'g1', 'g2'});
    });
  });

  group('DeviceListModel — eviction after ~3 missed beacons (D-02)', () {
    test('kBeaconEvictMillis is 7000 (~3 missed 2s intervals)', () {
      expect(kBeaconEvictMillis, 7000);
    });

    test('a remembered (stored) device flips live->false but stays listed',
        () {
      final model = DeviceListModel();
      model.mergeStored(
        {'g1': meta(key: 'g1', name: 'LAPTOP', host: '192.168.1.7')},
        {'g1'},
      );
      model.onBeacon(beaconFrom(guid: 'g1'), 1000);
      expect(model.entries.single.live, isTrue);

      model.sweep(1000 + kBeaconEvictMillis + 1);

      final entries = model.entries;
      expect(entries, hasLength(1),
          reason: 'remembered devices stay listed when they go quiet');
      expect(entries.single.live, isFalse);
      expect(entries.single.paired, isTrue);
    });

    test('an entry seen exactly kBeaconEvictMillis ago is still live', () {
      final model = DeviceListModel();
      model.onBeacon(beaconFrom(guid: 'g1'), 1000);

      model.sweep(1000 + kBeaconEvictMillis); // not MORE than — keep it

      expect(model.entries.single.live, isTrue,
          reason: 'eviction requires MORE than kBeaconEvictMillis of silence');
    });

    test('a discovery-only unpaired entry disappears on eviction', () {
      final model = DeviceListModel();
      model.onBeacon(beaconFrom(guid: 'g1'), 0);
      expect(model.entries, hasLength(1));

      model.sweep(kBeaconEvictMillis + 1);

      expect(model.entries, isEmpty,
          reason: 'nothing remembers it — no grayed ghost row');
    });
  });

  group('DeviceListModel — no per-packet churn (T-03-22)', () {
    test('an unchanged beacon produces an EQUAL entries list', () {
      final model = DeviceListModel();
      model.onBeacon(beaconFrom(guid: 'g1'), 0);
      final before = model.entries;

      model.onBeacon(beaconFrom(guid: 'g1'), 2000); // same host/port, later

      expect(model.entries, equals(before),
          reason: 'rows must never blink per packet — equality enables '
              'change-detection in the Notifier');
    });

    test('a host change DOES produce a different entries list', () {
      final model = DeviceListModel();
      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.7'), 0);
      final before = model.entries;

      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.99'), 2000);

      expect(model.entries, isNot(equals(before)));
    });
  });

  group('DeviceListModel — mergeStored (remembered-offline rows)', () {
    test('stored devices absent from beacons appear grayed at last-known '
        'host:port', () {
      final model = DeviceListModel();
      model.mergeStored(
        {
          'g9': meta(key: 'g9', name: 'DESKTOP', host: '10.0.0.5', port: 17778),
        },
        {'g9'},
      );

      final entries = model.entries;
      expect(entries, hasLength(1));
      expect(entries.single.live, isFalse);
      expect(entries.single.host, '10.0.0.5');
      expect(entries.single.port, 17778);
      expect(entries.single.paired, isTrue,
          reason: 'paired flag comes from the stored token set');
    });

    test('a stored device without a token is unpaired', () {
      final model = DeviceListModel();
      model.mergeStored({'g9': meta(key: 'g9')}, const <String>{});

      expect(model.entries.single.paired, isFalse);
    });

    test('a stored device that is ALSO live shows one live paired row', () {
      final model = DeviceListModel();
      model.mergeStored(
        {'g1': meta(key: 'g1', name: 'LAPTOP', host: '192.168.1.7')},
        {'g1'},
      );
      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.42'), 0);

      final entries = model.entries;
      expect(entries, hasLength(1), reason: 'no duplicate stored+live rows');
      expect(entries.single.live, isTrue);
      expect(entries.single.paired, isTrue);
      expect(entries.single.host, '192.168.1.42',
          reason: 'the live beacon address wins over the stored one');
    });
  });

  group('DeviceListModel — ordering (UI-SPEC list contract)', () {
    test('live entries sorted by name first, then grayed remembered', () {
      final model = DeviceListModel();
      model.mergeStored(
        {'g9': meta(key: 'g9', name: 'AAA-OFFLINE')},
        {'g9'},
      );
      model.onBeacon(
          beaconFrom(guid: 'g2', name: 'ZULU', source: '192.168.1.8'), 0);
      model.onBeacon(
          beaconFrom(guid: 'g1', name: 'ALPHA', source: '192.168.1.7'), 0);

      final entries = model.entries;
      expect(entries.map((e) => e.key).toList(), ['g1', 'g2', 'g9'],
          reason: 'live (ALPHA, ZULU by name) before grayed (AAA-OFFLINE), '
              'even though AAA sorts first alphabetically');
      expect(entries[0].live, isTrue);
      expect(entries[1].live, isTrue);
      expect(entries[2].live, isFalse);
    });
  });

  group('DeviceListModel — manual->GUID adoption (D-03)', () {
    test('a beacon from a stored manual entry\'s host adopts exactly once',
        () {
      final calls = <(String, String)>[];
      final model = DeviceListModel(
        onAdopt: (manualKey, guid) => calls.add((manualKey, guid)),
      );
      final manualKey = manualDeviceKey('192.168.1.7', 17777);
      model.mergeStored(
        {manualKey: meta(key: manualKey, host: '192.168.1.7')},
        {manualKey},
      );

      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.7'), 0);
      expect(calls, [(manualKey, 'g1')]);

      // Idempotent: a second identical beacon does not re-trigger.
      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.7'), 2000);
      expect(calls, hasLength(1),
          reason: 'adoption fires exactly once per manual entry');
    });

    test('a beacon from an unrelated host never triggers adoption', () {
      final calls = <(String, String)>[];
      final model = DeviceListModel(
        onAdopt: (manualKey, guid) => calls.add((manualKey, guid)),
      );
      final manualKey = manualDeviceKey('192.168.1.7', 17777);
      model.mergeStored({manualKey: meta(key: manualKey, host: '192.168.1.7')},
          const <String>{});

      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.99'), 0);

      expect(calls, isEmpty);
    });

    test('a stored GUID entry (non-manual) never triggers adoption', () {
      final calls = <(String, String)>[];
      final model = DeviceListModel(
        onAdopt: (manualKey, guid) => calls.add((manualKey, guid)),
      );
      model.mergeStored(
          {'g1': meta(key: 'g1', host: '192.168.1.7')}, const <String>{});

      model.onBeacon(beaconFrom(guid: 'g1', source: '192.168.1.7'), 0);

      expect(calls, isEmpty,
          reason: 'only manual:<host>:<port> keys are adoption candidates');
    });
  });
}
