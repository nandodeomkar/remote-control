/// Device-list state (D-02, CONN-01): pure merge/evict/adopt logic +
/// the Riverpod 3 Notifier that feeds it from the live seams.
///
/// TWO halves, deliberately split:
///
/// 1. [DeviceListModel] — PURE. No Flutter, no Riverpod, no timers, no IO:
///    every input carries an explicit `nowMillis` (latency_probe style), so
///    the whole merge/evict/adopt contract is unit-proven with a fake clock.
/// 2. [DeviceListNotifier] — a THIN Riverpod 3 [Notifier] wrapper owning the
///    real seams: a [BeaconListener] subscription (started when first
///    listened, stopped on disposal — Pitfall 8 screen-visible scoping), a
///    2s sweep [Timer], [DeviceStore.loadDevices] for the remembered rows,
///    and [DeviceStore.adoptGuid] for the manual->GUID migration (D-03).
///
/// Anti-churn contract (T-03-22): [DeviceListEntry] equality EXCLUDES
/// `lastSeenMillis`, so a beacon that changes nothing visible produces an
/// entries list equal to the previous one — the Notifier only publishes on
/// real change and rows never blink per packet.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/beacon.dart';
import '../net/beacon_listener.dart';
import '../net/connection_providers.dart';
import 'device_store.dart';

/// Silence window before a live entry grays out: ~3 missed 2s beacon
/// intervals (UI-SPEC "6-8s" eviction rule; strictly MORE than this).
const int kBeaconEvictMillis = 7000;

/// One row of the device list, in display order.
@immutable
class DeviceListEntry {
  /// Device key: a machine GUID, or `manual:<host>:<port>` pre-adoption.
  final String key;

  /// Display name (beacon name for live rows, stored name for grayed ones).
  final String name;

  /// The address a tap dials: live beacon source, or last-known stored host.
  final String host;

  /// The WebSocket port that pairs with [host].
  final int port;

  /// True while beacons are arriving; false for remembered-offline rows.
  final bool live;

  /// Whether a stored token exists for this device.
  final bool paired;

  /// Whether this is the currently-connected device (at most one row).
  final bool connected;

  /// Millis of the last accepted beacon (0 for never-seen stored rows).
  /// EXCLUDED from equality — see the anti-churn contract above.
  final int lastSeenMillis;

  /// Creates one immutable row.
  const DeviceListEntry({
    required this.key,
    required this.name,
    required this.host,
    required this.port,
    required this.live,
    required this.paired,
    required this.connected,
    required this.lastSeenMillis,
  });

  @override
  bool operator ==(Object other) =>
      other is DeviceListEntry &&
      other.key == key &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.live == live &&
      other.paired == paired &&
      other.connected == connected;
  // lastSeenMillis intentionally excluded: it advances every packet and
  // including it would defeat the no-per-packet-churn change detection.

  @override
  int get hashCode =>
      Object.hash(key, name, host, port, live, paired, connected);
}

/// Latest sighting of one guid (internal live-table row).
class _Sighting {
  String name;
  String host;
  int port;
  int lastSeenMillis;

  _Sighting({
    required this.name,
    required this.host,
    required this.port,
    required this.lastSeenMillis,
  });
}

/// PURE device-list logic: GUID merge, 7s eviction, stored-row overlay,
/// manual->GUID adoption. No IO, no Flutter, no Riverpod, no timers.
class DeviceListModel {
  /// Called EXACTLY ONCE per manual entry when a beacon's source host
  /// matches a stored `manual:<host>:<port>` row (the DeviceStore.adoptGuid
  /// seam — the callback does the storage migration; this model only
  /// detects the match).
  final void Function(String manualKey, String guid)? onAdopt;

  /// Live sightings keyed by guid — the beacon merge table.
  final Map<String, _Sighting> _live = <String, _Sighting>{};

  /// Remembered devices keyed by device key (from [mergeStored]).
  Map<String, DeviceMeta> _stored = const <String, DeviceMeta>{};

  /// Keys with a stored token (from [mergeStored]).
  Set<String> _paired = const <String>{};

  /// Manual keys whose adoption callback already fired (idempotence guard).
  final Set<String> _adopted = <String>{};

  /// The currently-connected device key, or null (set by the Notifier from
  /// ConnectionService state; drives [DeviceListEntry.connected]).
  String? connectedKey;

  /// Creates the model. [onAdopt] is optional so pure merge/evict tests
  /// need no callback plumbing.
  DeviceListModel({this.onAdopt});

  /// Feeds one validated beacon: merge by guid (new host/port replaces old —
  /// PC IP change recovery) and check the manual-adoption seam.
  void onBeacon(Beacon b, int nowMillis) {
    final existing = _live[b.guid];
    if (existing == null) {
      _live[b.guid] = _Sighting(
        name: b.name,
        host: b.host,
        port: b.port,
        lastSeenMillis: nowMillis,
      );
    } else {
      existing
        ..name = b.name
        ..host = b.host
        ..port = b.port
        ..lastSeenMillis = nowMillis;
    }
    _maybeAdopt(b);
  }

  /// Evicts sightings silent for MORE than [kBeaconEvictMillis]: a
  /// remembered device drops to its grayed stored row; a discovery-only
  /// unpaired device disappears entirely.
  void sweep(int nowMillis) {
    _live.removeWhere(
      (_, s) => nowMillis - s.lastSeenMillis > kBeaconEvictMillis,
    );
  }

  /// Replaces the remembered-device overlay: [stored] rows absent from the
  /// live table render grayed at their last-known address; [pairedKeys]
  /// drives every row's paired flag.
  void mergeStored(Map<String, DeviceMeta> stored, Set<String> pairedKeys) {
    _stored = Map<String, DeviceMeta>.of(stored);
    _paired = Set<String>.of(pairedKeys);
  }

  /// Display-ordered rows: live sorted by name, then grayed remembered
  /// (also by name). Stored devices that are live show ONE live row with
  /// the beacon's (fresher) address.
  List<DeviceListEntry> get entries {
    final live = _live.entries
        .map(
          (e) => DeviceListEntry(
            key: e.key,
            name: e.value.name,
            host: e.value.host,
            port: e.value.port,
            live: true,
            paired: _paired.contains(e.key),
            connected: e.key == connectedKey,
            lastSeenMillis: e.value.lastSeenMillis,
          ),
        )
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final grayed = _stored.entries
        .where((e) => !_live.containsKey(e.key))
        .map(
          (e) => DeviceListEntry(
            key: e.key,
            name: e.value.name,
            host: e.value.host,
            port: e.value.port,
            live: false,
            paired: _paired.contains(e.key),
            connected: e.key == connectedKey,
            lastSeenMillis: 0,
          ),
        )
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return List<DeviceListEntry>.unmodifiable([...live, ...grayed]);
  }

  /// Fires [onAdopt] when [b]'s SOURCE host matches a stored manual entry
  /// (never a payload field — T-03-13), exactly once per manual key.
  void _maybeAdopt(Beacon b) {
    final adopt = onAdopt;
    if (adopt == null) return;
    for (final entry in _stored.entries) {
      if (!entry.key.startsWith('manual:')) continue;
      if (entry.value.host != b.host) continue;
      if (!_adopted.add(entry.key)) continue; // already fired — idempotent
      adopt(entry.key, b.guid);
    }
  }
}

/// The [DeviceStore] singleton over real storage adapters. Kept here (not in
/// connection_providers) so the device list and future screens share one
/// definition; the same underlying prefs/keystore backs every instance.
final deviceStoreProvider = Provider<DeviceStore>(
  (ref) => DeviceStore(secure: SecureStorageKv(), prefs: SharedPrefsKv()),
);

/// Thin Riverpod 3 wrapper: owns the [BeaconListener] lifecycle (started on
/// first listen, stopped on disposal — Pitfall 8 screen-visible scoping; the
/// backoff re-listen case is 03-07's wiring), a 2s sweep [Timer], stored-row
/// loading, and the adoption migration. Rebuilds state from
/// [DeviceListModel.entries] ONLY when the list actually changed.
class DeviceListNotifier extends Notifier<List<DeviceListEntry>> {
  /// Sweep cadence — matches the server's 2s beacon interval.
  static const Duration _sweepInterval = Duration(seconds: 2);

  DeviceListModel? _model;
  BeaconListener? _listener;
  StreamSubscription<Beacon>? _beaconSub;
  StreamSubscription<void>? _connSub;
  Timer? _sweepTimer;

  @override
  List<DeviceListEntry> build() {
    final store = ref.watch(deviceStoreProvider);
    final service = ref.watch(connectionServiceProvider);

    final model = DeviceListModel(
      onAdopt: (manualKey, guid) => unawaited(_adopt(store, manualKey, guid)),
    );
    _model = model;

    // Beacon feed: start on first listen, stop with the provider (Pitfall 8).
    final listener = BeaconListener();
    _listener = listener;
    _beaconSub = listener.stream.listen((b) {
      model.onBeacon(b, DateTime.now().millisecondsSinceEpoch);
      _publish();
    });
    // 03-07: the D-06 beacon short-circuit — a sighting of the CURRENT
    // target's guid updates its last-known address and skips the remaining
    // backoff (CONN-04 IP-change recovery). The service holds its own
    // subscription; it is replaced on re-attach and cancelled on dispose.
    service.attachBeacons(listener.stream);
    unawaited(
      listener.start().catchError((Object _) {
        // Bind failure is retryable (OEM quirk / port in use): the grayed
        // stored rows still render; a later rebuild retries the bind.
      }),
    );

    // Eviction sweep: live -> grayed after >7s of silence.
    _sweepTimer = Timer.periodic(_sweepInterval, (_) {
      model.sweep(DateTime.now().millisecondsSinceEpoch);
      _publish();
    });

    // Connected-row marker: follow the service's lifecycle transitions.
    model.connectedKey = service.isAuthed ? service.target?.key : null;
    _connSub = service.changes.listen((_) {
      model.connectedKey = service.isAuthed ? service.target?.key : null;
      _publish();
    });

    // Remembered rows (async — state updates when loaded).
    unawaited(_reloadStored(store));

    ref.onDispose(() {
      _sweepTimer?.cancel();
      _sweepTimer = null;
      _beaconSub?.cancel();
      _beaconSub = null;
      _connSub?.cancel();
      _connSub = null;
      unawaited(_listener?.stop());
      _listener = null;
      _model = null;
    });

    return model.entries;
  }

  /// Loads stored devices + their paired flags into the model overlay.
  Future<void> _reloadStored(DeviceStore store) async {
    final devices = await store.loadDevices();
    final paired = <String>{
      for (final key in devices.keys)
        if (await store.isPaired(key)) key,
    };
    _model?.mergeStored(devices, paired);
    _publish();
  }

  /// Runs the storage migration for one adoption match, then re-syncs the
  /// stored overlay (the manual row re-keys to its guid).
  Future<void> _adopt(DeviceStore store, String manualKey, String guid) async {
    await store.adoptGuid(manualKey: manualKey, guid: guid);
    await _reloadStored(store);
  }

  /// Publishes the model's entries ONLY when the list changed (entry
  /// equality excludes lastSeenMillis — the anti-churn contract).
  void _publish() {
    final model = _model;
    if (model == null) return;
    final next = model.entries;
    if (listEquals(next, state)) return;
    state = next;
  }
}

/// The device list the phase-home screen watches (live rows first, then
/// grayed remembered rows).
final deviceListProvider =
    NotifierProvider<DeviceListNotifier, List<DeviceListEntry>>(
  DeviceListNotifier.new,
);
