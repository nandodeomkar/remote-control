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

// RED-phase stubs: every body throws UnimplementedError naming the
// implementing task (03-03 Task 2) so red-test panics identify the wave.

/// Minimal async KV seam over the platform secure store (Android keystore).
abstract interface class SecureKv {
  /// Reads the value for [key], or null when absent. May throw
  /// `PlatformException` on keystore invalidation (Pitfall 5).
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

/// Real adapter over `FlutterSecureStorage` (v10 default cipher — the
/// deprecated `encryptedSharedPreferences` option is never set).
class SecureStorageKv implements SecureKv {
  @override
  Future<String?> read(String key) =>
      throw UnimplementedError('03-03 Task 2 implements SecureStorageKv.read');

  @override
  Future<void> write(String key, String value) =>
      throw UnimplementedError('03-03 Task 2 implements SecureStorageKv.write');

  @override
  Future<void> delete(String key) => throw UnimplementedError(
      '03-03 Task 2 implements SecureStorageKv.delete');
}

/// Real adapter over the shared_preferences API.
class SharedPrefsKv implements PrefsKv {
  @override
  Future<String?> getString(String key) => throw UnimplementedError(
      '03-03 Task 2 implements SharedPrefsKv.getString');

  @override
  Future<void> setString(String key, String value) =>
      throw UnimplementedError(
          '03-03 Task 2 implements SharedPrefsKv.setString');
}

/// Non-secret metadata for one remembered PC.
///
/// NO TOKEN FIELD by construction — tokens live only in [SecureKv] under
/// `token.<key>` (secrets discipline).
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

  /// Serializes the Pattern-7 prefs entry (the [key] is the enclosing JSON
  /// map key, not part of the value).
  Map<String, Object?> toJson() =>
      throw UnimplementedError('03-03 Task 2 implements DeviceMeta.toJson');

  /// Deserializes one Pattern-7 prefs entry stored under [key].
  factory DeviceMeta.fromJson(String key, Map<String, Object?> json) =>
      throw UnimplementedError('03-03 Task 2 implements DeviceMeta.fromJson');
}

/// GUID-keyed CRUD over tokens (secure) + metadata (prefs).
class DeviceStore {
  // ignore: unused_field — wired in 03-03 Task 2 (GREEN).
  final SecureKv _secure;
  // ignore: unused_field — wired in 03-03 Task 2 (GREEN).
  final PrefsKv _prefs;

  /// Creates a store over injected seams (fakes in tests, real adapters live).
  DeviceStore({required SecureKv secure, required PrefsKv prefs})
      : _secure = secure,
        _prefs = prefs;

  /// The raw token for [deviceKey], or null when unpaired OR when the
  /// keystore read fails (Pitfall 5: degrade to unpaired, delete dead entry).
  Future<String?> tokenFor(String deviceKey) =>
      throw UnimplementedError('03-03 Task 2 implements tokenFor');

  /// Persists [token] under `token.<deviceKey>` in secure storage.
  Future<void> saveToken(String deviceKey, String token) =>
      throw UnimplementedError('03-03 Task 2 implements saveToken');

  /// Removes the token for [deviceKey].
  Future<void> deleteToken(String deviceKey) =>
      throw UnimplementedError('03-03 Task 2 implements deleteToken');

  /// Whether a token exists for [deviceKey] (false on keystore failure).
  Future<bool> isPaired(String deviceKey) =>
      throw UnimplementedError('03-03 Task 2 implements isPaired');

  /// All remembered devices, keyed by device key (empty map when none).
  Future<Map<String, DeviceMeta>> loadDevices() =>
      throw UnimplementedError('03-03 Task 2 implements loadDevices');

  /// Inserts or replaces [meta] in the prefs `devices` JSON map.
  Future<void> upsertDevice(DeviceMeta meta) =>
      throw UnimplementedError('03-03 Task 2 implements upsertDevice');

  /// Removes [deviceKey] from the prefs `devices` JSON map.
  Future<void> removeDevice(String deviceKey) =>
      throw UnimplementedError('03-03 Task 2 implements removeDevice');

  /// The last-connected device key (prefs `lastDeviceGuid`), or null.
  Future<String?> lastDeviceKey() =>
      throw UnimplementedError('03-03 Task 2 implements lastDeviceKey');

  /// Sets the last-connected pointer (prefs `lastDeviceGuid`).
  Future<void> setLastDevice(String deviceKey) =>
      throw UnimplementedError('03-03 Task 2 implements setLastDevice');

  /// Migrates a manual entry to its real GUID key once a beacon identifies
  /// the PC: moves the token to `token.<guid>`, re-keys the metadata, removes
  /// the manual entry, and updates `lastDeviceGuid` if it pointed at
  /// [manualKey].
  Future<void> adoptGuid({required String manualKey, required String guid}) =>
      throw UnimplementedError('03-03 Task 2 implements adoptGuid');
}

/// Synthetic device key for a by-IP connection made before any beacon is
/// seen: `manual:<host>:<port>` (the frozen wire protocol carries no GUID —
/// the beacon is the only GUID source).
String manualDeviceKey(String host, int port) =>
    throw UnimplementedError('03-03 Task 2 implements manualDeviceKey');
