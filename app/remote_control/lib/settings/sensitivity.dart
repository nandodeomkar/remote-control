/// The D-05 pointer-sensitivity setting: shared_preferences-backed store +
/// Riverpod 3 provider.
///
/// NON-SECRET by rule (CONTEXT D-05 / stack "What NOT to Use"): sensitivity
/// lives in shared_preferences ONLY — never flutter_secure_storage (keystore
/// ops are slow and can throw after OS updates; only the auth token is
/// secret).
///
/// TWO halves, following the device_store house pattern:
///
/// 1. [SensitivityStore] — a small typed store over an injectable
///    [SharedPreferencesAsync] (the current 2.5.x API, same adapter choice as
///    [SharedPrefsKv]). Reads degrade to [kSensitivityDefault] and every
///    value is clamped to the tuning.dart slider bounds, so a corrupt or
///    out-of-range stored double can never produce a wild gain.
/// 2. [SensitivityNotifier] — a thin Riverpod 3 unified [Notifier] (the
///    locked stack — no legacy v2 StateNotifier patterns) that seeds
///    [kSensitivityDefault] synchronously, loads the persisted value on
///    build, and persists through the store on [SensitivityNotifier.set].
///
/// HOT-PATH CONTRACT: consumers must NOT read this provider per pointer
/// event. The trackpad screen caches the double and updates the cache from a
/// provider listener; the driver's sensitivity getter reads the cached value.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../trackpad/tuning.dart';

/// The shared_preferences key holding the sensitivity double (D-05).
const String kSensitivityPrefsKey = 'pointer.sensitivity';

/// Typed store for the sensitivity double: clamped reads/writes over
/// shared_preferences (non-secret — never secure storage).
class SensitivityStore {
  final SharedPreferencesAsync _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  SensitivityStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  /// The persisted sensitivity, clamped to
  /// [kSensitivityMin]..[kSensitivityMax]; [kSensitivityDefault] when unset
  /// or when the platform read fails (a broken prefs read must never take
  /// the trackpad down — the default feel is always available).
  Future<double> load() async {
    try {
      final stored = await _prefs.getDouble(kSensitivityPrefsKey);
      if (stored == null) return kSensitivityDefault;
      return stored.clamp(kSensitivityMin, kSensitivityMax).toDouble();
    } on Object {
      return kSensitivityDefault;
    }
  }

  /// Persists [value] (clamped to the slider bounds) under
  /// [kSensitivityPrefsKey].
  Future<void> save(double value) => _prefs.setDouble(
        kSensitivityPrefsKey,
        value.clamp(kSensitivityMin, kSensitivityMax).toDouble(),
      );
}

/// The [SensitivityStore] singleton (overridable in tests).
final sensitivityStoreProvider = Provider<SensitivityStore>(
  (ref) => SensitivityStore(),
);

/// Riverpod 3 unified [Notifier] over the sensitivity value: synchronous
/// [kSensitivityDefault] seed, async load on build, clamped persist-through
/// on [set].
class SensitivityNotifier extends Notifier<double> {
  @override
  double build() {
    // Seed synchronously with the default so the very first MoveIntent has a
    // sane gain; replace with the persisted value as soon as it loads.
    unawaited(_load(ref.watch(sensitivityStoreProvider)));
    return kSensitivityDefault;
  }

  Future<void> _load(SensitivityStore store) async {
    state = await store.load();
  }

  /// Sets the sensitivity (clamped to the tuning.dart slider bounds),
  /// applying live and persisting immediately (fire-and-forget — a failed
  /// prefs write costs persistence, never responsiveness).
  void set(double value) {
    final clamped = value.clamp(kSensitivityMin, kSensitivityMax).toDouble();
    state = clamped;
    unawaited(ref.read(sensitivityStoreProvider).save(clamped));
  }
}

/// The D-05 sensitivity the tune sheet edits and the trackpad screen's
/// cached-double listener follows.
final sensitivityProvider = NotifierProvider<SensitivityNotifier, double>(
  SensitivityNotifier.new,
);
