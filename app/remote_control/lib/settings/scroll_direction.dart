/// The D-11 scroll-direction setting: shared_preferences-backed store +
/// Riverpod 3 provider + a hot-path-cached sign gate for the trackpad driver.
///
/// NON-SECRET by rule (stack "What NOT to Use"): the scroll-direction flag
/// lives in shared_preferences ONLY — never flutter_secure_storage (keystore
/// ops are slow and can throw after OS updates; only the auth token is
/// secret).
///
/// TWO halves, cloning the [SensitivityStore]/[SensitivityNotifier] house
/// pattern (07-PATTERNS SHARED-F), exactly like `haptics.dart`:
///
/// 1. [ScrollDirectionStore] — a small typed bool store over an injectable
///    [SharedPreferencesAsync]. A missing or failed read degrades to
///    [kScrollReversedDefault] (Natural/false), so a corrupt pref can never
///    silently flip the scroll direction.
/// 2. [ScrollDirectionNotifier] — a Riverpod 3 unified [Notifier] that seeds
///    Natural synchronously, loads the persisted bool on build, and persists
///    through the store on [ScrollDirectionNotifier.set].
///
/// HOT-PATH CONTRACT (mirrors haptics.dart / sensitivity.dart): the
/// trackpad driver's scroll-sign gate must NOT `ref.read` the pref per
/// scroll event. A top-level cached bool ([_scrollReversedCached]) is
/// updated from a single provider listener installed once via
/// [bindScrollDirectionCache]; [scrollReversedCached] reads only that cache.
/// `trackpad_screen.dart` installs the listener (mirrors `main.dart`
/// installing [bindHapticsCache]) and passes `scrollReversed:
/// () => scrollReversedCached` into [TrackpadDriver].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shared_preferences key holding the scroll-reversed bool (D-11).
const String kScrollDirectionPrefsKey = 'scroll.reversed';

/// The default scroll direction — Natural (not reversed).
const bool kScrollReversedDefault = false;

/// Typed store for the scroll-reversed bool over shared_preferences
/// (non-secret — never secure storage).
class ScrollDirectionStore {
  final SharedPreferencesAsync _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  ScrollDirectionStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  /// The persisted scroll-reversed flag; [kScrollReversedDefault] (Natural)
  /// when unset or when the platform read fails (a broken prefs read must
  /// never leave the trackpad in an unexpected sign).
  Future<bool> load() async {
    try {
      final stored = await _prefs.getBool(kScrollDirectionPrefsKey);
      return stored ?? kScrollReversedDefault;
    } on Object {
      return kScrollReversedDefault;
    }
  }

  /// Persists [value] under [kScrollDirectionPrefsKey].
  Future<void> save(bool value) =>
      _prefs.setBool(kScrollDirectionPrefsKey, value);
}

/// The [ScrollDirectionStore] singleton (overridable in tests).
final scrollDirectionStoreProvider = Provider<ScrollDirectionStore>(
  (ref) => ScrollDirectionStore(),
);

/// Riverpod 3 unified [Notifier] over the scroll-reversed flag: synchronous
/// Natural seed, async load on build, persist-through on [set].
class ScrollDirectionNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Seed Natural synchronously so the first scroll has a sane sign;
    // replace with the persisted value as soon as it loads.
    unawaited(_load(ref.watch(scrollDirectionStoreProvider)));
    return kScrollReversedDefault;
  }

  Future<void> _load(ScrollDirectionStore store) async {
    state = await store.load();
  }

  /// Sets the scroll direction (true = Reversed), applying live and
  /// persisting immediately (fire-and-forget — a failed prefs write costs
  /// persistence, never responsiveness).
  void set(bool value) {
    state = value;
    unawaited(ref.read(scrollDirectionStoreProvider).save(value));
  }
}

/// The D-11 scroll-direction flag the Settings segmented control edits and
/// the hot-path cache follows. `true` = Reversed, `false` = Natural.
final scrollDirectionProvider = NotifierProvider<ScrollDirectionNotifier, bool>(
  ScrollDirectionNotifier.new,
);

/// The hot-path cache the trackpad driver's scroll-sign gate reads. Updated
/// ONLY from the listener installed by [bindScrollDirectionCache]; never
/// `ref.read` per scroll event. Seeded Natural to match the synchronous
/// provider seed.
bool _scrollReversedCached = kScrollReversedDefault;

/// Installs the single listener that keeps [_scrollReversedCached] in sync
/// with [scrollDirectionProvider]. Call once from the trackpad screen's
/// `initState` (the same `listenManual` seam `bindHapticsCache` uses at the
/// app root, and the seam `trackpad_screen.dart` already uses for its
/// sensitivity cache). The subscription closes with the element;
/// `fireImmediately` primes the cache with the current value so no scroll
/// between mount and the first change is mis-gated.
void bindScrollDirectionCache(WidgetRef ref) {
  ref.listenManual<bool>(
    scrollDirectionProvider,
    (_, next) => _scrollReversedCached = next,
    fireImmediately: true,
  );
}

/// The current cached scroll-direction flag (`true` = Reversed). Reads ONLY
/// the cache — never triggers a provider lookup on the hot path. The
/// trackpad driver's `scrollReversed` seam reads this directly.
bool get scrollReversedCached => _scrollReversedCached;

/// Test-only accessor for the hot-path cache, so the sign gate can be driven
/// deterministically without a prefs backend or a provider container.
@visibleForTesting
bool get debugScrollReversedCached => _scrollReversedCached;

/// Test-only setter for the hot-path cache (see [debugScrollReversedCached]).
@visibleForTesting
set debugScrollReversedCached(bool value) => _scrollReversedCached = value;
