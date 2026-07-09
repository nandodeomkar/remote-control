/// GUID-keyed multi-PC device store (D-07, D-10).
///
/// Storage schema (03-RESEARCH Pattern 7, exact):
///
/// ```
/// flutter_secure_storage:            shared_preferences:
///   "token.<deviceKey>" = 64-hex       "devices" = JSON: { "<deviceKey>":
///                                         {"name","host","port","lastConnectedAt"} }
///                                      "lastDeviceGuid" = "<deviceKey>"
/// ```
///
/// SECRETS RULE (PATTERNS "Secrets discipline"): the raw auth token string
/// lives ONLY in secure storage under `token.<deviceKey>`. It never enters
/// shared_preferences, logs, or any object that gets `toString()`d —
/// [DeviceMeta] has no token field BY CONSTRUCTION.
///
/// Device keys are machine GUIDs from the discovery beacon. Connections made
/// by IP before any beacon is seen use the synthetic key
/// `manual:<host>:<port>` ([manualDeviceKey]); [DeviceStore.adoptGuid]
/// migrates such an entry to its real GUID once a beacon identifies the PC
/// (D-03: a successful manual connection is remembered like a discovered one).
///
/// Storage seams ([SecureKv], [PrefsKv]) are constructor-injected
/// (latency_probe.dart style) so tests run against fakes — including a fake
/// secure store that throws [PlatformException] on demand (Pitfall 5:
/// keystore invalidation after OS update/restore, flutter_secure_storage
/// issue #853, must degrade to unpaired — never crash).
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal async KV seam over the platform secure store (Android keystore).
abstract interface class SecureKv {
  /// Reads the value for [key], or null when absent. May throw
  /// [PlatformException] on keystore invalidation (Pitfall 5).
  Future<String?> read(String key);

  /// Writes [value] under [key].
  Future<void> write(String key, String value);

  /// Deletes [key] (no-op when absent).
  Future<void> delete(String key);
}

/// Minimal async KV seam over shared_preferences (non-secrets ONLY).
abstract interface class PrefsKv {
  /// Reads the string for [key], or null when absent.
  Future<String?> getString(String key);

  /// Writes [value] under [key].
  Future<void> setString(String key, String value);
}

/// Real adapter over [FlutterSecureStorage] with v10 defaults: the current
/// Android cipher (RSA_ECB_OAEP + SHA-256) with NO options overridden — the
/// deprecated encrypted-prefs flag from v9 is never set (stack rule).
class SecureStorageKv implements SecureKv {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Real adapter over [SharedPreferencesAsync] (the current 2.5.x API).
///
/// Kept deliberately thin so the shared_preferences API choice is invisible
/// to [DeviceStore]; an instance may be injected for platform tests.
class SharedPrefsKv implements PrefsKv {
  final SharedPreferencesAsync _prefs;

  /// Wraps [prefs], defaulting to a fresh [SharedPreferencesAsync].
  SharedPrefsKv({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  @override
  Future<String?> getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
}

/// Non-secret metadata for one remembered PC.
///
/// NO TOKEN FIELD by construction — tokens live only in [SecureKv] under
/// `token.<key>`, so serializing, logging, or `toString()`ing a [DeviceMeta]
/// can never leak a secret (secrets discipline).
class DeviceMeta {
  /// Device key: a machine GUID, or `manual:<host>:<port>` pre-adoption.
  final String key;

  /// Human-readable device name from the beacon (or the host for manual).
  final String name;

  /// Last-known host (IP or name).
  final String host;

  /// Last-known WebSocket port.
  final int port;

  /// Millis-since-epoch of the last successful connection, if any.
  final int? lastConnectedAt;

  /// Creates immutable metadata for one device.
  const DeviceMeta({
    required this.key,
    required this.name,
    required this.host,
    required this.port,
    this.lastConnectedAt,
  });

  /// Serializes the Pattern-7 prefs entry. The [key] is the enclosing JSON
  /// map key, not part of the value — matching the schema exactly.
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'host': host,
        'port': port,
        if (lastConnectedAt != null) 'lastConnectedAt': lastConnectedAt,
      };

  /// Deserializes one Pattern-7 prefs entry stored under [key].
  factory DeviceMeta.fromJson(String key, Map<String, Object?> json) =>
      DeviceMeta(
        key: key,
        name: json['name']! as String,
        host: json['host']! as String,
        port: (json['port']! as num).toInt(),
        lastConnectedAt: (json['lastConnectedAt'] as num?)?.toInt(),
      );
}

/// GUID-keyed CRUD over tokens (secure storage) + metadata (prefs).
///
/// Every [SecureKv] read/delete is wrapped in `on PlatformException` per
/// Pitfall 5: a keystore failure degrades the device to unpaired (null
/// token) and attempts to delete the dead entry — it never crashes.
class DeviceStore {
  static const String _devicesPrefsKey = 'devices';
  static const String _lastDevicePrefsKey = 'lastDeviceGuid';

  final SecureKv _secure;
  final PrefsKv _prefs;

  /// Creates a store over injected seams (fakes in tests, real adapters live).
  DeviceStore({required SecureKv secure, required PrefsKv prefs})
      : _secure = secure, // ignore: prefer_initializing_formals
        _prefs = prefs; // ignore: prefer_initializing_formals

  static String _tokenKey(String deviceKey) => 'token.$deviceKey';

  /// The raw token for [deviceKey], or null when unpaired OR when the
  /// keystore read fails (Pitfall 5: degrade to unpaired, delete the dead
  /// entry with the cleanup failure swallowed too).
  Future<String?> tokenFor(String deviceKey) async {
    final key = _tokenKey(deviceKey);
    try {
      return await _secure.read(key);
    } on PlatformException {
      // Keystore invalidation (OS update / restore, issue #853): treat the
      // device as unpaired and clean up the dead entry; a failure of the
      // cleanup itself is swallowed as well.
      try {
        await _secure.delete(key);
      } on PlatformException {
        // Swallowed: the entry is dead either way; pairing will rewrite it.
      }
      return null;
    }
  }

  /// Persists [token] under `token.<deviceKey>` in secure storage.
  Future<void> saveToken(String deviceKey, String token) =>
      _secure.write(_tokenKey(deviceKey), token);

  /// Removes the token for [deviceKey] (keystore failures swallowed).
  Future<void> deleteToken(String deviceKey) async {
    try {
      await _secure.delete(_tokenKey(deviceKey));
    } on PlatformException {
      // Swallowed per Pitfall 5: a failed delete of a dead entry is benign.
    }
  }

  /// Whether a token exists for [deviceKey] (false on keystore failure).
  Future<bool> isPaired(String deviceKey) async =>
      await tokenFor(deviceKey) != null;

  /// All remembered devices, keyed by device key (empty map when none).
  ///
  /// Total by construction: a single corrupt or schema-drifted entry is
  /// skipped rather than failing the whole load, matching the "never crash on
  /// a stored read" posture used for tokens (Pitfall 5). Callers get the good
  /// rows; a bad row simply won't appear until pairing rewrites it.
  Future<Map<String, DeviceMeta>> loadDevices() async {
    final raw = await _loadRawDevices();
    final out = <String, DeviceMeta>{};
    for (final entry in raw.entries) {
      try {
        out[entry.key] = DeviceMeta.fromJson(
          entry.key,
          (entry.value! as Map).cast<String, Object?>(),
        );
      } on Object {
        // Skip a corrupt/incomplete row (bad type, missing field) — do not let
        // one dead entry break loading + adoption for every remembered device.
      }
    }
    return out;
  }

  /// Inserts or replaces [meta] in the prefs `devices` JSON map.
  Future<void> upsertDevice(DeviceMeta meta) async {
    final raw = await _loadRawDevices();
    raw[meta.key] = meta.toJson();
    await _saveRawDevices(raw);
  }

  /// Removes [deviceKey] from the prefs `devices` JSON map.
  Future<void> removeDevice(String deviceKey) async {
    final raw = await _loadRawDevices();
    raw.remove(deviceKey);
    await _saveRawDevices(raw);
  }

  /// The last-connected device key (prefs `lastDeviceGuid`), or null.
  Future<String?> lastDeviceKey() => _prefs.getString(_lastDevicePrefsKey);

  /// Sets the last-connected pointer (prefs `lastDeviceGuid`).
  Future<void> setLastDevice(String deviceKey) =>
      _prefs.setString(_lastDevicePrefsKey, deviceKey);

  /// Migrates a manual entry to its real GUID key once a beacon identifies
  /// the PC (D-03): moves the token to `token.<guid>`, re-keys the metadata
  /// (name/host/port/lastConnectedAt preserved), removes the manual entry,
  /// and updates `lastDeviceGuid` if it pointed at [manualKey].
  Future<void> adoptGuid({
    required String manualKey,
    required String guid,
  }) async {
    // Token: move (read is Pitfall-5-wrapped; a dead manual token simply
    // leaves the guid unpaired — normal pairing takes over).
    final token = await tokenFor(manualKey);
    if (token != null) {
      await _secure.write(_tokenKey(guid), token);
    }
    await deleteToken(manualKey);

    // Metadata: re-key the raw JSON entry (the value schema carries no key,
    // so moving it under the guid is the whole migration).
    final raw = await _loadRawDevices();
    final manualJson = raw.remove(manualKey);
    if (manualJson != null) {
      raw[guid] = manualJson;
    }
    await _saveRawDevices(raw);

    // Pointer: follow the migration only if it pointed at the manual entry.
    if (await lastDeviceKey() == manualKey) {
      await setLastDevice(guid);
    }
  }

  Future<Map<String, Object?>> _loadRawDevices() async {
    final json = await _prefs.getString(_devicesPrefsKey);
    if (json == null) return <String, Object?>{};
    try {
      return (jsonDecode(json) as Map).cast<String, Object?>();
    } on Object {
      // Corrupt top-level blob (invalid JSON, wrong shape): degrade to "no
      // remembered devices" rather than throwing into every caller. Pairing
      // rewrites the key on the next successful connection.
      return <String, Object?>{};
    }
  }

  Future<void> _saveRawDevices(Map<String, Object?> raw) =>
      _prefs.setString(_devicesPrefsKey, jsonEncode(raw));
}

/// Synthetic device key for a by-IP connection made before any beacon is
/// seen: `manual:<host>:<port>` (the frozen wire protocol carries no GUID —
/// the beacon is the only GUID source).
String manualDeviceKey(String host, int port) => 'manual:$host:$port';
