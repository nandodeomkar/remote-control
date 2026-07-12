/// The D-13 haptics-enabled setting: shared_preferences-backed store +
/// Riverpod 3 provider + a hot-path-cached [hapticTick] gate.
///
/// NON-SECRET by rule (stack "What NOT to Use"): the haptics flag lives in
/// shared_preferences ONLY — never flutter_secure_storage (keystore ops are
/// slow and can throw after OS updates; only the auth token is secret).
///
/// TWO halves, cloning the [SensitivityStore]/[SensitivityNotifier] house
/// pattern:
///
/// 1. [HapticsStore] — a small typed bool store over an injectable
///    [SharedPreferencesAsync]. A missing or failed read degrades to
///    [kHapticsDefault] (ON), so a corrupt pref can never silently kill
///    haptics.
/// 2. [HapticsNotifier] — a Riverpod 3 unified [Notifier] that seeds ON
///    synchronously, loads the persisted bool on build, and persists through
///    the store on [HapticsNotifier.set].
///
/// HOT-PATH CONTRACT (mirrors sensitivity.dart L21-24): the ~15 haptic call
/// sites must NOT `ref.read` the pref per tap. Instead a top-level cached bool
/// ([_hapticsCached]) is updated from a single provider listener installed once
/// via [bindHapticsCache]; [hapticTick]/[hapticTickMedium] read only that
/// cache. 07-10 routes every call site through these two functions.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shared_preferences key holding the haptics-enabled bool (D-13).
const String kHapticsPrefsKey = 'haptics.enabled';

/// The default haptics state — ON (D-13: "default ON").
const bool kHapticsDefault = true;

/// Typed store for the haptics bool over shared_preferences (non-secret —
/// never secure storage).
class HapticsStore {
  final SharedPreferencesAsync _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  HapticsStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  /// The persisted haptics flag; [kHapticsDefault] (ON) when unset or when the
  /// platform read fails (a broken prefs read must never leave the user
  /// wondering why taps went quiet).
  Future<bool> load() async {
    try {
      final stored = await _prefs.getBool(kHapticsPrefsKey);
      return stored ?? kHapticsDefault;
    } on Object {
      return kHapticsDefault;
    }
  }

  /// Persists [value] under [kHapticsPrefsKey].
  Future<void> save(bool value) => _prefs.setBool(kHapticsPrefsKey, value);
}

/// The [HapticsStore] singleton (overridable in tests).
final hapticsStoreProvider = Provider<HapticsStore>(
  (ref) => HapticsStore(),
);

/// Riverpod 3 unified [Notifier] over the haptics flag: synchronous ON seed,
/// async load on build, persist-through on [set].
class HapticsNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Seed ON synchronously so the first tap ticks; replace with the persisted
    // value as soon as it loads.
    unawaited(_load(ref.watch(hapticsStoreProvider)));
    return kHapticsDefault;
  }

  Future<void> _load(HapticsStore store) async {
    state = await store.load();
  }

  /// Toggles haptics, applying live and persisting immediately (fire-and-forget
  /// — a failed prefs write costs persistence, never responsiveness).
  void set(bool value) {
    state = value;
    unawaited(ref.read(hapticsStoreProvider).save(value));
  }
}

/// The D-13 haptics-enabled flag the settings toggle edits and the hot-path
/// cache follows.
final hapticsEnabledProvider = NotifierProvider<HapticsNotifier, bool>(
  HapticsNotifier.new,
);

/// The hot-path cache the tick helpers read. Updated ONLY from the listener
/// installed by [bindHapticsCache]; never `ref.read` per tap. Seeded ON to
/// match the synchronous provider seed.
bool _hapticsCached = kHapticsDefault;

/// Installs the single listener that keeps [_hapticsCached] in sync with
/// [hapticsEnabledProvider]. Call once from `initState` near the app root (the
/// same `listenManual` seam the trackpad uses for its sensitivity cache). The
/// subscription closes with the element; `fireImmediately` primes the cache
/// with the current value so no tap between mount and the first change is
/// mis-gated.
void bindHapticsCache(WidgetRef ref) {
  ref.listenManual<bool>(
    hapticsEnabledProvider,
    (_, next) => _hapticsCached = next,
    fireImmediately: true,
  );
}

/// Test-only accessor for the hot-path cache, so the gate can be driven
/// deterministically without a prefs backend or a provider container.
@visibleForTesting
bool get debugHapticsCached => _hapticsCached;

/// Test-only setter for the hot-path cache (see [debugHapticsCached]).
@visibleForTesting
set debugHapticsCached(bool value) => _hapticsCached = value;

/// Fires a light haptic tick — but ONLY when haptics are enabled (the cached
/// pref). This is the gate the ~15 light call sites route through instead of
/// calling [HapticFeedback.lightImpact] directly (07-10).
void hapticTick() {
  if (_hapticsCached) HapticFeedback.lightImpact();
}

/// Fires a medium haptic tick (the stronger power-screen confirm), still gated
/// on the cached pref. Mirrors [hapticTick] but uses
/// [HapticFeedback.mediumImpact].
void hapticTickMedium() {
  if (_hapticsCached) HapticFeedback.mediumImpact();
}
